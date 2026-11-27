<#
  movies.ps1 - set up Radarr the way you want it, then organize your movies.

  Usage (from CMD, in this folder):
    movies setup                 one-time setup (safe to run again)
    movies organize D:\Downloads  sort the movies in a folder into your library
    movies search                look for missing movies and 5.1 upgrades
    movies status                show what Radarr is set to

  What "setup" does in Radarr:
    * Quality profile "1080p 5.1": 1080p at most (no 4K, no huge remuxes).
      Releases with 5.1 surround are preferred. If none exists, a normal 1080p
      is downloaded, and Radarr swaps it for a 5.1 copy when one shows up.
    * Renames every movie as "Title (Year)\Title (Year) [quality, audio].mkv".
    * Saves posters, fanart and a .nfo (plot, cast, genres) next to every movie,
      using Radarr's public movie database (TMDb).
    * Puts the library on the drive you pick. Finished downloads are moved out
      of your download folder onto that drive.

  Works with Windows PowerShell 5.1 (built into Windows 10/11) and PowerShell 7.
#>
param(
    [Parameter(Position = 0)] [string] $Command = "help",
    [Parameter(Position = 1)] [string] $Path,
    [string] $Url,
    [string] $ApiKey,
    [switch] $Allow720p
)

$ErrorActionPreference = "Stop"
$ProfileName = "1080p 5.1"
$SurroundName = "Surround 5.1"
# "5.1" in a release name: DDP5.1, AAC5.1, DTS-HD.MA.5.1, "5 1"... but not 2005.1080p or H.265.1080p
$SurroundRegex = '(?<![0-9])5[ ._]1(?![0-9])'
$SurroundScore = 100
$VideoExt = @(".mkv", ".mp4", ".avi", ".m4v", ".mov", ".wmv", ".ts", ".m2ts", ".mpg", ".mpeg", ".webm")

$SettingsDir = Join-Path $env:APPDATA "MovieSetup"
$SettingsFile = Join-Path $SettingsDir "settings.json"

# ------------------------------------------------------------------ helpers

function Say($text, $color = "Gray") { Write-Host $text -ForegroundColor $color }
function Good($text) { Say "  [ok] $text" Green }
function Warn($text) { Say "  [!]  $text" Yellow }
function Fail($text) { Say "  [x]  $text" Red; exit 1 }

function Load-Settings {
    if (Test-Path $SettingsFile) {
        try { return Get-Content $SettingsFile -Raw | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{ url = ""; apiKey = ""; root = ""; profileId = 0 }
}

function Save-Settings($s) {
    if (-not (Test-Path $SettingsDir)) { New-Item -ItemType Directory -Path $SettingsDir | Out-Null }
    $s | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8
}

function Find-ApiKey {
    # Radarr keeps its API key here on Windows (both installer and tray versions).
    foreach ($p in @("$env:ProgramData\Radarr\config.xml", "$env:LOCALAPPDATA\Radarr\config.xml")) {
        if ($p -and (Test-Path $p)) {
            try {
                $xml = [xml](Get-Content $p -Raw)
                if ($xml.Config.ApiKey) { return $xml.Config.ApiKey }
            } catch { }
        }
    }
    return ""
}

function Api($method, $endpoint, $body = $null) {
    $uri = $script:Base.TrimEnd("/") + "/api/v3/" + $endpoint
    $req = @{ Method = $method; Uri = $uri; Headers = @{ "X-Api-Key" = $script:Key }; UseBasicParsing = $true }
    if ($null -ne $body) {
        $json = ConvertTo-Json -InputObject $body -Depth 30 -Compress
        $req.Body = [Text.Encoding]::UTF8.GetBytes($json)
        $req.ContentType = "application/json; charset=utf-8"
    }
    try {
        $result = Invoke-RestMethod @req
    } catch {
        $detail = ""
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $detail = $_.ErrorDetails.Message
            try { $j = $detail | ConvertFrom-Json; if ($j.message) { $detail = $j.message } elseif ($j[0].errorMessage) { $detail = $j[0].errorMessage } } catch { }
            if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) + "..." }
        }
        throw "Radarr said no to $method $endpoint : $($_.Exception.Message) $detail"
    }
    # PowerShell 7 hands back a JSON list as one object; send its items out one by one
    # so @(Api GET ...) is always a plain list on both PowerShell 5.1 and 7.
    return $result
}

function Connect-Radarr($s) {
    $script:Base = if ($Url) { $Url } elseif ($s.url) { $s.url } else { "http://localhost:7878" }
    $script:Key = if ($ApiKey) { $ApiKey } elseif ($s.apiKey) { $s.apiKey } else { Find-ApiKey }
    if (-not $script:Key) {
        Say "Couldn't find Radarr's API key automatically."
        Say "In Radarr open Settings > General > Security and copy the API Key."
        $script:Key = (Read-Host "Paste the API key").Trim()
    }
    try {
        $status = Api GET "system/status"
    } catch {
        Say ""
        Say "Can't reach Radarr at $script:Base" Red
        Say "  * Is Radarr running? (open $script:Base in your browser)"
        Say "  * Not installed yet? Get it free from https://radarr.video (Windows installer)"
        Say "  * Different address? run:  movies setup -Url http://localhost:7878"
        Say "  * Wrong key? run:          movies setup -ApiKey YOURKEY"
        exit 1
    }
    $s.url = $script:Base; $s.apiKey = $script:Key
    Save-Settings $s
    Good "Connected to Radarr $($status.version) at $script:Base"
}

function Pick-Drive($current) {
    Say ""
    Say "Where should your movie library live?" Cyan
    $drives = @(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\$' -and $_.Free -ne $null })
    $i = 0
    foreach ($d in $drives) {
        $i++
        $free = [math]::Round($d.Free / 1GB)
        $label = ""
        try { $label = (Get-Volume -DriveLetter $d.Name -ErrorAction Stop).FileSystemLabel } catch { }
        Say ("  {0}) {1}  {2,6} GB free  {3}" -f $i, $d.Root, $free, $label)
    }
    if ($current) { Say "  Enter) keep $current" }
    Say "  Or type a full folder path, like E:\Media\Movies"
    while ($true) {
        $ans = (Read-Host "Choose").Trim().Trim('"')
        if (-not $ans -and $current) { return $current }
        if ($ans -match '^\d+$' -and [int]$ans -ge 1 -and [int]$ans -le $drives.Count) {
            return (Join-Path $drives[[int]$ans - 1].Root "Movies")
        }
        if ([IO.Path]::IsPathRooted($ans)) { return $ans }
        Warn "Type a number from the list or a full path."
    }
}

function Ask-YesNo($question, $default = $false) {
    $hint = if ($default) { "[Y/n]" } else { "[y/N]" }
    $a = (Read-Host "$question $hint").Trim().ToLower()
    if (-not $a) { return $default }
    return $a.StartsWith("y")
}

function Wait-Command($cmd, $what) {
    $deadline = (Get-Date).AddMinutes(30)
    while ((Get-Date) -lt $deadline) {
        $c = Api GET "command/$($cmd.id)"
        if ($c.status -in @("completed", "failed", "aborted", "cancelled", "orphaned")) { return $c }
        Start-Sleep -Seconds 2
    }
    Warn "$what is still running in Radarr; check Activity > Queue."
    return $null
}

# ------------------------------------------------------------------ setup steps

function Ensure-SurroundFormat {
    $spec = [ordered]@{
        name = "5.1 in release name"; implementation = "ReleaseTitleSpecification"
        negate = $false; required = $true
        fields = @(@{ name = "value"; value = $SurroundRegex })
    }
    $existing = @(Api GET "customformat") | Where-Object { $_.name -eq $SurroundName } | Select-Object -First 1
    if ($existing) {
        $existing.specifications = @($spec)
        Api PUT "customformat/$($existing.id)" $existing | Out-Null
        Good "Custom format '$SurroundName' updated"
        return $existing.id
    }
    $cf = Api POST "customformat" ([ordered]@{ name = $SurroundName; includeCustomFormatWhenRenaming = $false; specifications = @($spec) })
    Good "Custom format '$SurroundName' created"
    return $cf.id
}

function Ensure-Profile($surroundId) {
    $wanted = @("HDTV-1080p", "WEBDL-1080p", "WEBRip-1080p", "Bluray-1080p")
    if ($Allow720p) { $wanted += @("HDTV-720p", "WEBDL-720p", "WEBRip-720p", "Bluray-720p") }

    $existing = @(Api GET "qualityprofile") | Where-Object { $_.name -eq $ProfileName } | Select-Object -First 1
    $p = if ($existing) { $existing } else { Api GET "qualityprofile/schema" }

    $cutoff = 0
    foreach ($item in $p.items) {
        if ($item.quality) {
            $item.allowed = $wanted -contains $item.quality.name
            if ($item.quality.name -eq "Bluray-1080p") { $cutoff = $item.quality.id }
        } else {
            $names = @($item.items | ForEach-Object { $_.quality.name })
            $on = @($names | Where-Object { $wanted -contains $_ }).Count -gt 0
            $item.allowed = $on
            foreach ($sub in $item.items) { $sub.allowed = $wanted -contains $sub.quality.name }
        }
    }
    if (-not $cutoff) { Fail "Couldn't find Bluray-1080p in Radarr's qualities." }

    # Score: 5.1 releases get +100. Everything else 0, so a normal copy is still fine.
    $found = $false
    foreach ($f in $p.formatItems) {
        if ($f.format -eq $surroundId) { $f.score = $SurroundScore; $found = $true }
    }
    if (-not $found) {
        $p.formatItems = @($p.formatItems) + @([pscustomobject]@{ format = $surroundId; name = $SurroundName; score = $SurroundScore })
    }

    $p.name = $ProfileName
    $p.upgradeAllowed = $true          # swap the normal copy for a 5.1 one later
    $p.cutoff = $cutoff                # stop upgrading quality at Bluray-1080p...
    $p.minFormatScore = 0              # ...a non-5.1 release is still allowed
    $p.cutoffFormatScore = $SurroundScore  # ...and stop upgrading once we have 5.1
    $p.minUpgradeFormatScore = 1

    if ($existing) {
        Api PUT "qualityprofile/$($p.id)" $p | Out-Null
        Good "Quality profile '$ProfileName' updated"
        return $p.id
    }
    $p.PSObject.Properties.Remove("id")
    $new = Api POST "qualityprofile" $p
    Good "Quality profile '$ProfileName' created"
    return $new.id
}

function Set-Naming {
    $n = Api GET "config/naming"
    $n.renameMovies = $true
    $n.replaceIllegalCharacters = $true
    $n.colonReplacementFormat = "dash"
    $n.movieFolderFormat = "{Movie CleanTitle} ({Release Year})"
    $n.standardMovieFormat = "{Movie CleanTitle} ({Release Year}) [{Quality Full}][{MediaInfo AudioCodec} {MediaInfo AudioChannels}]{-Release Group}"
    Api PUT "config/naming/$($n.id)" $n | Out-Null
    Good "Renaming on: 'Movie Title (Year)\Movie Title (Year) [Bluray-1080p][EAC3 5.1].mkv'"
}

function Set-MediaManagement {
    $m = Api GET "config/mediamanagement"
    $m.importExtraFiles = $true
    $m.extraFileExtensions = "srt,sub,idx,ass,ssa"
    $m.deleteEmptyFolders = $true
    $m.createEmptyMovieFolders = $false
    $m.autoRenameFolders = $true
    $m.enableMediaInfo = $true
    $m.copyUsingHardlinks = $true
    Api PUT "config/mediamanagement/$($m.id)" $m | Out-Null
    Good "Subtitles come along, empty folders are cleaned up"
}

function Set-Metadata {
    $kodi = @(Api GET "metadata") | Where-Object { $_.implementation -eq "XbmcMetadata" } | Select-Object -First 1
    if (-not $kodi) { Warn "Kodi metadata option not found; skipping posters/.nfo"; return }
    $kodi.enable = $true
    foreach ($f in $kodi.fields) {
        switch ($f.name) {
            "movieMetadata" { $f.value = $true }
            "movieImages" { $f.value = $true }
            "addCollectionName" { $f.value = $true }
        }
    }
    Api PUT "metadata/$($kodi.id)" $kodi | Out-Null
    Good "Posters, fanart and .nfo info files (from TMDb) saved next to every movie"
}

function Ensure-RootFolder($path) {
    if (-not (Test-Path $path)) {
        try { New-Item -ItemType Directory -Path $path -Force | Out-Null } catch { Fail "Couldn't create $path : $_" }
    }
    $roots = @(Api GET "rootfolder")
    $match = $roots | Where-Object { $_.path.TrimEnd("\") -ieq $path.TrimEnd("\") } | Select-Object -First 1
    if ($match) { Good "Library folder: $path"; return }
    Api POST "rootfolder" @{ path = $path } | Out-Null
    Good "Library folder added: $path"
}

function Check-DownloadClient {
    $clients = @(Api GET "downloadclient") | Where-Object { $_.enable }
    if ($clients.Count -eq 0) {
        Warn "Radarr has no download client yet. Add yours in Settings > Download Clients."
        Warn "Once it's there, finished downloads are moved to your library automatically."
        return
    }
    Good ("Download client: " + (($clients | ForEach-Object { $_.name }) -join ", ") + "  (finished downloads get moved into the library)")
    $dl = Api GET "config/downloadclient"
    if (-not $dl.enableCompletedDownloadHandling) {
        $dl.enableCompletedDownloadHandling = $true
        Api PUT "config/downloadclient/$($dl.id)" $dl | Out-Null
        Good "Turned on Completed Download Handling"
    }
}

function Move-ExistingMovies($profileId, $root) {
    $movies = @(Api GET "movie")
    if ($movies.Count -eq 0) { return }
    Say ""
    Say "Radarr already has $($movies.Count) movie(s)." Cyan
    if (-not (Ask-YesNo "Switch them all to '$ProfileName'?" $true)) { return }
    $ids = @($movies | ForEach-Object { $_.id })
    $body = [ordered]@{ movieIds = $ids; qualityProfileId = $profileId }
    $elsewhere = @($movies | Where-Object { -not $_.path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) })
    if ($elsewhere.Count -gt 0 -and (Ask-YesNo "Move $($elsewhere.Count) of them (files too) to $root ? This can take a while." $false)) {
        $body.rootFolderPath = $root
        $body.moveFiles = $true
    }
    Api PUT "movie/editor" $body | Out-Null
    Good "Existing movies updated (moves run in the background, see System > Tasks)"
}

# ------------------------------------------------------------------ commands

function Do-Setup {
    $s = Load-Settings
    Say "Movie setup for Radarr" Cyan
    Connect-Radarr $s
    $root = Pick-Drive $s.root
    Say ""
    $cf = Ensure-SurroundFormat
    $pid_ = Ensure-Profile $cf
    Set-Naming
    Set-MediaManagement
    Set-Metadata
    Ensure-RootFolder $root
    Check-DownloadClient
    $s.root = $root; $s.profileId = $pid_
    Save-Settings $s
    Move-ExistingMovies $pid_ $root
    Say ""
    Say "Done." Green
    Say "When you add a movie in Radarr, pick:  Quality profile '$ProfileName'  and folder '$root'."
    Say "Got loose movies in a folder already?  movies organize D:\Downloads"
    Say "Re-download everything at the new quality:  movies search"
}

function Need-Setup {
    $s = Load-Settings
    if (-not $s.root -or -not $s.profileId) { Fail "Run 'movies setup' first." }
    Connect-Radarr $s
    return $s
}

function Get-Items($folder) {
    # Each sub-folder is one movie; loose video files at the top level are one movie each.
    $items = @()
    $items += @(Get-ChildItem -LiteralPath $folder -Directory | Where-Object {
        @(Get-ChildItem -LiteralPath $_.FullName -Recurse -File | Where-Object { $VideoExt -contains $_.Extension.ToLower() }).Count -gt 0
    })
    $items += @(Get-ChildItem -LiteralPath $folder -File | Where-Object { $VideoExt -contains $_.Extension.ToLower() })
    return $items
}

function Find-Or-Add-Movie($name, $s) {
    $parsed = Api GET ("parse?title=" + [uri]::EscapeDataString($name))
    if ($parsed.movie) { return $parsed.movie }
    $info = $parsed.parsedMovieInfo
    if (-not $info -or -not $info.movieTitle) { return $null }
    $term = $info.movieTitle
    if ($info.year) { $term = "$term $($info.year)" }
    $hits = @(Api GET ("movie/lookup?term=" + [uri]::EscapeDataString($term)))
    $hit = $hits | Where-Object { -not $info.year -or $_.year -eq $info.year } | Select-Object -First 1
    if (-not $hit) { return $null }
    if ($hit.id) { return $hit }   # already in the library
    $hit | Add-Member -NotePropertyName qualityProfileId -NotePropertyValue $s.profileId -Force
    $hit | Add-Member -NotePropertyName rootFolderPath -NotePropertyValue $s.root -Force
    $hit | Add-Member -NotePropertyName monitored -NotePropertyValue $true -Force
    $hit | Add-Member -NotePropertyName minimumAvailability -NotePropertyValue "released" -Force
    $hit | Add-Member -NotePropertyName addOptions -NotePropertyValue @{ searchForMovie = $false } -Force
    return Api POST "movie" $hit
}

function Do-Organize {
    if (-not $Path) { Fail "Which folder?  Example:  movies organize D:\Downloads" }
    $folder = (Resolve-Path -LiteralPath $Path).ProviderPath
    $s = Need-Setup
    $items = @(Get-Items $folder)
    if ($items.Count -eq 0) { Say "No movies found in $folder"; return }
    Say "Found $($items.Count) movie(s) in $folder. Moving them to $($s.root)" Cyan
    $done = 0; $skipped = @()
    foreach ($it in $items) {
        $name = if ($it.PSIsContainer) { $it.Name } else { $it.BaseName }
        Say ""
        Say "  $name"
        try { $movie = Find-Or-Add-Movie $name $s } catch { $movie = $null; Warn $_ }
        if (-not $movie) { Warn "Couldn't match this to a movie. Rename it like 'Title (Year)' and try again."; $skipped += $name; continue }
        Say "    -> $($movie.title) ($($movie.year))"
        $cmd = Api POST "command" @{ name = "DownloadedMoviesScan"; path = $it.FullName; importMode = "Move" }
        $res = Wait-Command $cmd "Import"
        $after = Api GET "movie/$($movie.id)"
        if ($after.hasFile -and -not (Test-Path -LiteralPath $it.FullName)) {
            Good "Moved to $($after.path)"; $done++
        } elseif ($after.hasFile) {
            Warn "Radarr kept the copy it already had (this one wasn't better). Left in place."
            $skipped += $name
        } else {
            $msg = if ($res -and $res.message) { $res.message } else { "see Radarr > Activity > Queue / Wanted > Manual Import" }
            Warn "Not imported: $msg"; $skipped += $name
        }
    }
    Say ""
    Say "Moved $done of $($items.Count)." Green
    if ($skipped.Count) { Say "Left alone: $($skipped -join '; ')" Yellow }
}

function Do-Search {
    $s = Need-Setup
    Api POST "command" @{ name = "MissingMoviesSearch" } | Out-Null
    Good "Searching for missing movies"
    Api POST "command" @{ name = "CutOffUnmetMoviesSearch" } | Out-Null
    Good "Searching for upgrades (normal -> 5.1, lower -> 1080p)"
    Say "Watch progress in Radarr > Activity."
}

function Do-Status {
    $s = Load-Settings
    Connect-Radarr $s
    Say "  Library folder : $($s.root)"
    $p = @(Api GET "qualityprofile") | Where-Object { $_.name -eq $ProfileName } | Select-Object -First 1
    if ($p) {
        $q = @()
        foreach ($i in $p.items) { if ($i.allowed) { if ($i.quality) { $q += $i.quality.name } else { $q += $i.name } } }
        Say "  Profile        : $ProfileName  ($($q -join ', '); 5.1 preferred)"
    } else { Say "  Profile        : not set up yet (run 'movies setup')" }
    $movies = @(Api GET "movie")
    $have = @($movies | Where-Object { $_.hasFile }).Count
    Say "  Movies         : $have downloaded, $($movies.Count - $have) missing"
}

switch ($Command.ToLower()) {
    "setup"    { Do-Setup }
    "organize" { Do-Organize }
    "organise" { Do-Organize }
    "search"   { Do-Search }
    "status"   { Do-Status }
    default {
        Say "movies setup                  set up Radarr (1080p, 5.1 preferred, library on a drive you pick)"
        Say "movies organize D:\Downloads  move the movies in a folder into your library, with posters and info"
        Say "movies search                 find missing movies and 5.1 upgrades"
        Say "movies status                 show the current setup"
        Say ""
        Say "Options: -Url http://host:7878  -ApiKey KEY  -Allow720p (setup: also accept 720p if no 1080p)"
    }
}
