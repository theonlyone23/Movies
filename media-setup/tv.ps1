<#
  tv.ps1 - set up Sonarr the way you want it, then organize your TV shows.

  Usage (from CMD, in this folder):
    tv setup                  one-time setup (safe to run again)
    tv organize D:\Downloads  sort the shows/episodes in a folder into your library
    tv search                 look for missing episodes and 5.1 upgrades
    tv status                 show what Sonarr is set to

  What "setup" does in Sonarr (v4):
    * Quality profile "1080p 5.1": 1080p at most (no 4K, no huge remuxes).
      Releases with 5.1 surround are preferred. If none exists, a normal 1080p
      is downloaded, and Sonarr swaps it for a 5.1 copy when one shows up.
    * Renames episodes as "Show (Year)\Season 01\Show (Year) - S01E01 - Title [quality, audio].mkv".
    * Saves show/season/episode artwork and .nfo info files, from Sonarr's public
      TV database (TheTVDB).
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
$SettingsFile = Join-Path $SettingsDir "tv-settings.json"

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
    # Sonarr keeps its API key here on Windows (both installer and tray versions).
    foreach ($p in @("$env:ProgramData\Sonarr\config.xml", "$env:LOCALAPPDATA\Sonarr\config.xml")) {
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
        throw "Sonarr said no to $method $endpoint : $($_.Exception.Message) $detail"
    }
    # PowerShell 7 hands back a JSON list as one object; send its items out one by one
    # so @(Api GET ...) is always a plain list on both PowerShell 5.1 and 7.
    return $result
}

function Connect-Sonarr($s) {
    $script:Base = if ($Url) { $Url } elseif ($s.url) { $s.url } else { "http://localhost:8989" }
    $script:Key = if ($ApiKey) { $ApiKey } elseif ($s.apiKey) { $s.apiKey } else { Find-ApiKey }
    if (-not $script:Key) {
        Say "Couldn't find Sonarr's API key automatically."
        Say "In Sonarr open Settings > General > Security and copy the API Key."
        $script:Key = (Read-Host "Paste the API key").Trim()
    }
    try {
        $status = Api GET "system/status"
    } catch {
        Say ""
        Say "Can't reach Sonarr at $script:Base" Red
        Say "  * Is Sonarr running? (open $script:Base in your browser)"
        Say "  * Not installed yet? Get it free from https://sonarr.tv (Windows installer)"
        Say "  * Different address? run:  tv setup -Url http://localhost:8989"
        Say "  * Wrong key? run:          tv setup -ApiKey YOURKEY"
        exit 1
    }
    if ([int]($status.version.Split(".")[0]) -lt 4) {
        Fail "This needs Sonarr v4 or newer (you have $($status.version)). Update from https://sonarr.tv"
    }
    $s.url = $script:Base; $s.apiKey = $script:Key
    Save-Settings $s
    Good "Connected to Sonarr $($status.version) at $script:Base"
}

function Pick-Drive($current) {
    Say ""
    Say "Where should your TV library live?" Cyan
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
    Say "  Or type a full folder path, like E:\Media\TV"
    while ($true) {
        $ans = (Read-Host "Choose").Trim().Trim('"')
        if (-not $ans -and $current) { return $current }
        if ($ans -match '^\d+$' -and [int]$ans -ge 1 -and [int]$ans -le $drives.Count) {
            return (Join-Path $drives[[int]$ans - 1].Root "TV")
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
    Warn "$what is still running in Sonarr; check Activity > Queue."
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

    # Stop upgrading quality at WEB 1080p: most shows come out as WEB-DL, and chasing
    # Blu-ray copies would re-download whole seasons. (5.1 upgrades still happen.)
    $cutoff = 0
    foreach ($item in $p.items) {
        if ($item.quality) {
            $item.allowed = $wanted -contains $item.quality.name
        } else {
            $names = @($item.items | ForEach-Object { $_.quality.name })
            $item.allowed = @($names | Where-Object { $wanted -contains $_ }).Count -gt 0
            foreach ($sub in $item.items) { $sub.allowed = $wanted -contains $sub.quality.name }
            if ($names -contains "WEBDL-1080p") { $cutoff = $item.id }
        }
    }
    if (-not $cutoff) { Fail "Couldn't find the WEB 1080p group in Sonarr's qualities." }

    # Score: 5.1 releases get +100. Everything else 0, so a normal copy is still fine.
    $found = $false
    foreach ($f in $p.formatItems) {
        if ($f.format -eq $surroundId) { $f.score = $SurroundScore; $found = $true }
    }
    if (-not $found) {
        $p.formatItems = @($p.formatItems) + @([pscustomobject]@{ format = $surroundId; name = $SurroundName; score = $SurroundScore })
    }

    $p.name = $ProfileName
    $p.upgradeAllowed = $true
    $p.cutoff = $cutoff
    $p.minFormatScore = 0
    $p.cutoffFormatScore = $SurroundScore
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
    $n.renameEpisodes = $true
    $n.replaceIllegalCharacters = $true
    $tail = " [{Quality Full}][{MediaInfo AudioCodec} {MediaInfo AudioChannels}]{-Release Group}"
    $n.standardEpisodeFormat = "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle}" + $tail
    $n.dailyEpisodeFormat = "{Series TitleYear} - {Air-Date} - {Episode CleanTitle}" + $tail
    $n.animeEpisodeFormat = "{Series TitleYear} - S{season:00}E{episode:00} - {absolute:000} - {Episode CleanTitle}" + $tail
    $n.seriesFolderFormat = "{Series TitleYear}"
    $n.seasonFolderFormat = "Season {season:00}"
    $n.specialsFolderFormat = "Specials"
    Api PUT "config/naming/$($n.id)" $n | Out-Null
    Good "Renaming on: 'Show (2019)\Season 01\Show (2019) - S01E01 - Pilot [WEBDL-1080p][EAC3 5.1].mkv'"
}

function Set-MediaManagement {
    $m = Api GET "config/mediamanagement"
    $m.importExtraFiles = $true
    $m.extraFileExtensions = "srt,sub,idx,ass,ssa"
    $m.deleteEmptyFolders = $true
    $m.createEmptySeriesFolders = $false
    $m.enableMediaInfo = $true
    $m.copyUsingHardlinks = $true
    Api PUT "config/mediamanagement/$($m.id)" $m | Out-Null
    Good "Subtitles come along, empty folders are cleaned up"
}

function Set-Metadata {
    $kodi = @(Api GET "metadata") | Where-Object { $_.implementation -eq "XbmcMetadata" } | Select-Object -First 1
    if (-not $kodi) { Warn "Kodi metadata option not found; skipping artwork/.nfo"; return }
    $kodi.enable = $true
    foreach ($f in $kodi.fields) {
        if (@("seriesMetadata", "episodeMetadata", "seriesImages", "seasonImages", "episodeImages") -contains $f.name) { $f.value = $true }
    }
    Api PUT "metadata/$($kodi.id)" $kodi | Out-Null
    Good "Show, season and episode artwork plus .nfo info files (from TheTVDB) saved with your shows"
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
        Warn "Sonarr has no download client yet. Add yours in Settings > Download Clients."
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

function Move-ExistingSeries($profileId, $root) {
    $shows = @(Api GET "series")
    if ($shows.Count -eq 0) { return }
    Say ""
    Say "Sonarr already has $($shows.Count) show(s)." Cyan
    if (-not (Ask-YesNo "Switch them all to '$ProfileName'?" $true)) { return }
    $ids = @($shows | ForEach-Object { $_.id })
    $body = [ordered]@{ seriesIds = $ids; qualityProfileId = $profileId }
    $elsewhere = @($shows | Where-Object { -not $_.path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) })
    if ($elsewhere.Count -gt 0 -and (Ask-YesNo "Move $($elsewhere.Count) of them (files too) to $root ? This can take a while." $false)) {
        $body.rootFolderPath = $root
        $body.moveFiles = $true
    }
    Api PUT "series/editor" $body | Out-Null
    Good "Existing shows updated (moves run in the background, see System > Tasks)"
}

# ------------------------------------------------------------------ commands

function Do-Setup {
    $s = Load-Settings
    Say "TV setup for Sonarr" Cyan
    Connect-Sonarr $s
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
    Move-ExistingSeries $pid_ $root
    Say ""
    Say "Done." Green
    Say "When you add a show in Sonarr, pick:  Quality profile '$ProfileName'  and folder '$root'."
    Say "Got loose episodes in a folder already?  tv organize D:\Downloads"
    Say "Download everything missing:  tv search"
}

function Need-Setup {
    $s = Load-Settings
    if (-not $s.root -or -not $s.profileId) { Fail "Run 'tv setup' first." }
    Connect-Sonarr $s
    return $s
}

function Get-Videos($item) {
    if (-not $item.PSIsContainer) { return @($item) }
    return @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File | Where-Object {
        $VideoExt -contains $_.Extension.ToLower() -and $_.Name -notmatch '(?i)\bsample\b'
    })
}

function Get-Items($folder) {
    # Each sub-folder is one show, season or episode; loose video files count one each.
    $items = @()
    $items += @(Get-ChildItem -LiteralPath $folder -Directory | Where-Object { @(Get-Videos $_).Count -gt 0 })
    $items += @(Get-ChildItem -LiteralPath $folder -File | Where-Object { $VideoExt -contains $_.Extension.ToLower() })
    return $items
}

function Parse-Name($name) {
    $p = Api GET ("parse?title=" + [uri]::EscapeDataString($name))
    $title = $null; $year = 0
    if ($p.parsedEpisodeInfo) {
        $title = $p.parsedEpisodeInfo.seriesTitle
        if ($p.parsedEpisodeInfo.seriesTitleInfo) { $year = [int]$p.parsedEpisodeInfo.seriesTitleInfo.year }
    }
    return [pscustomobject]@{ series = $p.series; title = $title; year = $year }
}

function Find-Or-Add-Series($item, $s) {
    $name = if ($item.PSIsContainer) { $item.Name } else { $item.BaseName }
    $guess = Parse-Name $name
    if (-not $guess.series -and -not $guess.title) {
        # A plain show folder like "Office Plants (2019)": try an episode file inside.
        $first = Get-Videos $item | Select-Object -First 1
        if ($first) { $guess = Parse-Name $first.BaseName }
    }
    if ($guess.series) { return $guess.series }
    $term = $guess.title
    if (-not $term) {
        $term = ($name -replace '[._]', ' ' -replace '\[.*?\]', '' -replace '(?i)\b(complete|season.*|s\d{1,2}.*|1080p.*|720p.*|2160p.*)$', '').Trim()
    }
    if (-not $term) { return $null }
    $hits = @(Api GET ("series/lookup?term=" + [uri]::EscapeDataString($term)))
    $hit = $hits | Where-Object { -not $guess.year -or $_.year -eq $guess.year } | Select-Object -First 1
    if (-not $hit) { return $null }
    if ($hit.id) { return $hit }   # already in the library
    $hit | Add-Member -NotePropertyName qualityProfileId -NotePropertyValue $s.profileId -Force
    $hit | Add-Member -NotePropertyName rootFolderPath -NotePropertyValue $s.root -Force
    $hit | Add-Member -NotePropertyName monitored -NotePropertyValue $true -Force
    $hit | Add-Member -NotePropertyName seasonFolder -NotePropertyValue $true -Force
    $hit | Add-Member -NotePropertyName addOptions -NotePropertyValue @{ monitor = "all"; searchForMissingEpisodes = $false; searchForCutoffUnmetEpisodes = $false } -Force
    $added = Api POST "series" $hit
    # Sonarr fetches the episode list in the background; wait for it so the import can match episodes.
    for ($i = 0; $i -lt 30; $i++) {
        if (@(Api GET "episode?seriesId=$($added.id)").Count -gt 0) { break }
        Start-Sleep -Seconds 2
    }
    return $added
}

function Import-Path($p) {
    $cmd = Api POST "command" @{ name = "DownloadedEpisodesScan"; path = $p; importMode = "Move" }
    return Wait-Command $cmd "Import"
}

function Do-Organize {
    if (-not $Path) { Fail "Which folder?  Example:  tv organize D:\Downloads" }
    $folder = (Resolve-Path -LiteralPath $Path).ProviderPath
    $s = Need-Setup
    $items = @(Get-Items $folder)
    if ($items.Count -eq 0) { Say "No TV episodes found in $folder"; return }
    Say "Found $($items.Count) item(s) in $folder. Moving them to $($s.root)" Cyan
    $moved = 0; $total = 0; $skipped = @()
    foreach ($it in $items) {
        $before = @(Get-Videos $it)
        $total += $before.Count
        Say ""
        Say "  $($it.Name)  ($($before.Count) episode file(s))"
        try { $show = Find-Or-Add-Series $it $s } catch { $show = $null; Warn $_ }
        if (-not $show) { Warn "Couldn't match this to a show. Rename it like 'Show Name S01E01' and try again."; $skipped += $it.Name; continue }
        Say "    -> $($show.title) ($($show.year))"
        $res = Import-Path $it.FullName
        # Anything the folder import didn't take: try those files one at a time.
        if ($it.PSIsContainer -and (Test-Path -LiteralPath $it.FullName)) {
            foreach ($f in @(Get-Videos $it)) { Import-Path $f.FullName | Out-Null }
        }
        $left = if (Test-Path -LiteralPath $it.FullName) { @(Get-Videos $it).Count } else { 0 }
        $moved += $before.Count - $left
        if ($left -eq 0) {
            Good "All $($before.Count) moved"
        } else {
            $msg = if ($res -and $res.message) { " ($($res.message))" } else { "" }
            Warn "$left file(s) left in place$msg. Sonarr skips copies that aren't better than what you have; see Wanted > Manual Import for the rest."
            $skipped += $it.Name
        }
    }
    Say ""
    Say "Moved $moved of $total episode file(s)." Green
    if ($skipped.Count) { Say "Not finished: $($skipped -join '; ')" Yellow }
}

function Do-Search {
    $s = Need-Setup
    Api POST "command" @{ name = "MissingEpisodeSearch" } | Out-Null
    Good "Searching for missing episodes"
    Api POST "command" @{ name = "CutoffUnmetEpisodeSearch" } | Out-Null
    Good "Searching for upgrades (normal -> 5.1, lower -> 1080p)"
    Say "Watch progress in Sonarr > Activity."
}

function Do-Status {
    $s = Load-Settings
    Connect-Sonarr $s
    Say "  Library folder : $($s.root)"
    $p = @(Api GET "qualityprofile") | Where-Object { $_.name -eq $ProfileName } | Select-Object -First 1
    if ($p) {
        $q = @()
        foreach ($i in $p.items) { if ($i.allowed) { if ($i.quality) { $q += $i.quality.name } else { $q += $i.name } } }
        Say "  Profile        : $ProfileName  ($($q -join ', '); 5.1 preferred)"
    } else { Say "  Profile        : not set up yet (run 'tv setup')" }
    $shows = @(Api GET "series")
    $have = 0; $all = 0
    foreach ($sh in $shows) { if ($sh.statistics) { $have += $sh.statistics.episodeFileCount; $all += $sh.statistics.episodeCount } }
    Say "  Shows          : $($shows.Count)  ($have of $all monitored episodes downloaded)"
}

switch ($Command.ToLower()) {
    "setup"    { Do-Setup }
    "organize" { Do-Organize }
    "organise" { Do-Organize }
    "search"   { Do-Search }
    "status"   { Do-Status }
    default {
        Say "tv setup                  set up Sonarr (1080p, 5.1 preferred, library on a drive you pick)"
        Say "tv organize D:\Downloads  move the episodes in a folder into your library, with artwork and info"
        Say "tv search                 find missing episodes and 5.1 upgrades"
        Say "tv status                 show the current setup"
        Say ""
        Say "Options: -Url http://host:8989  -ApiKey KEY  -Allow720p (setup: also accept 720p if no 1080p)"
    }
}
