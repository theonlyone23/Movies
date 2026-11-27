<#
  library.ps1 - find duplicate movies and episodes across all your drives, keep the
  best copy, and gather everything onto one drive in a clean layout.

  Nothing is ever deleted without you typing DELETE. Extra copies are first moved
  into a "_Duplicates" folder on their own drive (instant, no copying), every move
  is logged, and "library undo" puts the last run back.

  Usage (from CMD, in this folder):
    library scan D: E: F:                    report only: what's where, what's duplicated
    library dedupe D: E: F:                  move the extra copies into X:\_Duplicates
    library consolidate D: E: F: -To G:      move the kept copies to G:\Movies and G:\TV
    library purge D: E: F:                   permanently delete the _Duplicates folders
    library undo                             put back everything the last dedupe/consolidate moved

  Which copy is "best": 1080p first (use -Prefer4K to rank 4K above it), then
  surround sound (5.1/7.1) over stereo, then the bigger file (higher bitrate).
  Install FFmpeg for exact info read from the files (winget install Gyan.FFmpeg);
  without it, quality is read from the file names.

  Works with Windows PowerShell 5.1 (built into Windows 10/11) and PowerShell 7.
#>
param(
    [Parameter(Position = 0)] [string] $Command = "help",
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)] [string[]] $Paths,
    [string] $To,
    [switch] $Prefer4K,
    [switch] $Yes
)

$ErrorActionPreference = "Stop"
$VideoExt = @(".mkv", ".mp4", ".avi", ".m4v", ".mov", ".wmv", ".ts", ".m2ts", ".mpg", ".mpeg", ".webm", ".divx", ".flv")
$SideExt = @(".srt", ".sub", ".idx", ".ass", ".ssa", ".vtt", ".sup", ".nfo", ".jpg", ".jpeg", ".png", ".tbn")
$SkipDirs = @('$RECYCLE.BIN', 'System Volume Information', '_Duplicates', 'Windows', 'Program Files',
    'Program Files (x86)', 'ProgramData', 'AppData', 'Sample', 'Samples', 'Extras', 'Featurettes',
    'Behind The Scenes', 'Deleted Scenes', 'Trailers', 'Interviews', 'Shorts', 'Other')
$DupFolder = "_Duplicates"
$AppDir = Join-Path $env:APPDATA "MovieSetup"
$LogDir = Join-Path $AppDir "logs"
$CacheFile = Join-Path $AppDir "mediainfo-cache.json"

function Say($text, $color = "Gray") { Write-Host $text -ForegroundColor $color }
function Good($text) { Say "  [ok] $text" Green }
function Warn($text) { Say "  [!]  $text" Yellow }
function Fail($text) { Say "  [x]  $text" Red; exit 1 }
function Size($bytes) {
    if ($bytes -ge 1TB) { return "{0:N2} TB" -f ($bytes / 1TB) }
    if ($bytes -ge 1GB) { return "{0:N1} GB" -f ($bytes / 1GB) }
    return "{0:N0} MB" -f ($bytes / 1MB)
}

# ------------------------------------------------------------------ input

function Normalize-Path($p) {
    $p = $p.Trim().Trim('"').Trim("'")
    if ($p -match '^[A-Za-z]:$') { $p += "\" }
    if (-not (Test-Path -LiteralPath $p)) { Fail "Can't find $p" }
    return (Resolve-Path -LiteralPath $p).ProviderPath
}

function Get-Roots {
    if ($Paths -and $Paths.Count) { return @($Paths | Where-Object { $_ } | ForEach-Object { Normalize-Path $_ }) }
    Say "Which drives or folders hold your movies and TV shows?" Cyan
    $drives = @(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\$' -and $_.Used -gt 0 })
    $i = 0
    foreach ($d in $drives) {
        $i++
        $label = ""
        try { $label = (Get-Volume -DriveLetter $d.Name -ErrorAction Stop).FileSystemLabel } catch { }
        Say ("  {0}) {1}  {2} used  {3}" -f $i, $d.Root, (Size $d.Used), $label)
    }
    Say "Type numbers separated by commas (like 2,3,4), or folder paths separated by commas."
    $ans = (Read-Host "Choose").Trim()
    $roots = @()
    foreach ($part in $ans.Split(",")) {
        $part = $part.Trim()
        if (-not $part) { continue }
        if ($part -match '^\d+$' -and [int]$part -ge 1 -and [int]$part -le $drives.Count) { $roots += $drives[[int]$part - 1].Root }
        else { $roots += Normalize-Path $part }
    }
    if (-not $roots.Count) { Fail "Nothing chosen." }
    return $roots
}

# ------------------------------------------------------------------ reading names and files

function Clean($text) {
    $t = $text -replace '\[[^\]]*\]', ' ' -replace '[._]', ' ' -replace '\s+', ' '
    $t = $t.Trim(" -([")
    if ($t -match '^(.*), (The|A|An)$') { $t = $Matches[2] + " " + $Matches[1] }   # "Thing, The" -> "The Thing"
    return $t
}

function Norm-Key($text) {
    $t = $text.ToLower() -replace '&', 'and' -replace "['’]", ''
    $t = $t -replace ', (the|a|an)$', '' -replace '^(the|a|an) ', ''
    return ($t -replace '[^a-z0-9]', '')
}

$QualityWords = '(?i)[ ._\-\[\(](2160p|1080p|1080i|720p|576p|480p|4k|uhd|bluray|blu-ray|bdrip|brrip|web-?dl|webrip|web|hdtv|dvdrip|dvd|remux|x264|x265|h ?264|h ?265|hevc|xvid|divx|hdr|proper|repack|10bit)\b.*$'

function Describe-Name($file) {
    # Works out what a video file is from its name and folders.
    $stem = [IO.Path]::GetFileNameWithoutExtension($file.Name)
    $parent = $file.Directory.Name
    $info = [ordered]@{ kind = "movie"; title = ""; year = ""; season = 0; episode = ""; extra = "" }

    $ep = [regex]::Match($stem, '(?i)\bS(\d{1,2})[ ._-]*((?:E\d{1,3}[ ._-]*)+)|\b(\d{1,2})x(\d{2,3})\b')
    if ($ep.Success) {
        $info.kind = "tv"
        if ($ep.Groups[1].Success) {
            $info.season = [int]$ep.Groups[1].Value
            $nums = @([regex]::Matches($ep.Groups[2].Value, '\d+') | ForEach-Object { [int]$_.Value })
        } else {
            $info.season = [int]$ep.Groups[3].Value
            $nums = @([int]$ep.Groups[4].Value)
        }
        $info.episode = ($nums | ForEach-Object { "E{0:D2}" -f $_ }) -join "-"
        $show = Clean $stem.Substring(0, $ep.Index)
        if (-not $show) {
            # "S01E01.mkv" inside "Show Name\Season 1\": use the folders.
            $d = $file.Directory
            if ($d.Name -match '(?i)^(season|series|s)\s*\d+|^specials$') { $d = $d.Parent }
            if ($d) { $show = Clean $d.Name }
        }
        $y = [regex]::Match($show, '\(?((?:19|20)\d{2})\)?$')
        if ($y.Success) { $info.year = $y.Groups[1].Value; $show = $show.Substring(0, $y.Index).Trim(" -(") }
        $info.title = $show
        return $info
    }

    # Movie. Generic names ("movie", "video", the release group) -> use the folder name.
    $name = $stem
    if ($stem.Length -lt 4 -or $stem -match '(?i)^(movie|video|film|feature|main|title\d*|[a-z]{2,4}-[a-z0-9]{2,6})$') { $name = $parent }
    $m = [regex]::Match($name, '^(.*?)[ ._\(\[-]+((?:19|20)\d{2})(?:[ ._\)\]-]|$)')
    if (-not $m.Success -and $name -ne $parent) {
        $m2 = [regex]::Match($parent, '^(.*?)[ ._\(\[-]+((?:19|20)\d{2})(?:[ ._\)\]-]|$)')
        if ($m2.Success) { $name = $parent; $m = $m2 }
    }
    if ($m.Success -and $m.Groups[1].Value.Trim()) {
        $info.title = Clean $m.Groups[1].Value
        $info.year = $m.Groups[2].Value
    } else {
        $info.title = Clean ($name -replace $QualityWords, '')
    }
    # Keep different parts and cuts apart, so CD1/CD2 or a Director's Cut is never called a duplicate.
    $extras = @()
    $pm = [regex]::Match($stem, '(?i)\b(cd|disc|disk|part|pt)[ ._-]?(\d{1,2})\b')
    if ($pm.Success) { $extras += "part" + [int]$pm.Groups[2].Value }
    $em = [regex]::Match($stem + " " + $parent, "(?i)director'?s[ ._-]?cut|extended|unrated|theatrical|final[ ._-]?cut|ultimate|uncut|special[ ._-]?edition|imax|3d\b")
    if ($em.Success) { $extras += (Norm-Key $em.Value) }
    $info.extra = $extras -join "+"
    # "Kill Bill CD1" and "CD2" share one "Kill Bill (2003)" folder.
    $info.title = ($info.title -replace '(?i)[ -]*\b(cd|disc|disk)[ ._-]?\d{1,2}\b', '').Trim(" -")
    return $info
}

$script:Cache = @{}
$script:HaveProbe = [bool](Get-Command ffprobe -ErrorAction SilentlyContinue)

function Load-Cache {
    if (Test-Path $CacheFile) {
        try {
            $raw = Get-Content $CacheFile -Raw | ConvertFrom-Json
            foreach ($p in $raw.PSObject.Properties) { $script:Cache[$p.Name] = $p.Value }
        } catch { }
    }
}
function Save-Cache {
    if (-not (Test-Path $AppDir)) { New-Item -ItemType Directory -Path $AppDir | Out-Null }
    [pscustomobject]$script:Cache | ConvertTo-Json -Depth 4 -Compress | Set-Content $CacheFile -Encoding UTF8
}

function Res-Class($w, $h) {
    if ($w -ge 3200 -or $h -ge 1800) { return 2160 }
    if ($w -ge 1800 -or $h -ge 1000) { return 1080 }
    if ($w -ge 1200 -or $h -ge 700) { return 720 }
    if ($w -gt 0) { return 480 }
    return 0
}

function Get-Quality($file) {
    $key = "$($file.FullName)|$($file.Length)|$($file.LastWriteTimeUtc.Ticks)"
    if ($script:Cache.ContainsKey($key)) { return $script:Cache[$key] }
    $q = [ordered]@{ res = 0; channels = 0; hdr = $false; codec = ""; from = "name" }
    if ($script:HaveProbe) {
        try {
            $json = & ffprobe -v quiet -print_format json -show_streams -- "$($file.FullName)" 2>$null | Out-String
            $streams = @(($json | ConvertFrom-Json).streams)
            $v = $streams | Where-Object { $_.codec_type -eq "video" -and -not ($_.disposition -and $_.disposition.attached_pic -eq 1) } | Select-Object -First 1
            if ($v) {
                $q.res = Res-Class ([int]$v.width) ([int]$v.height)
                $q.codec = "$($v.codec_name)"
                $q.hdr = ("$($v.color_transfer)" -match 'smpte2084|arib-std-b67') -or ("$($v.side_data_list)" -match 'DOVI')
                $q.from = "file"
            }
            $a = @($streams | Where-Object { $_.codec_type -eq "audio" } | ForEach-Object { [int]$_.channels })
            if ($a.Count) { $q.channels = ($a | Measure-Object -Maximum).Maximum }
        } catch { }
    }
    $n = $file.Name + " " + $file.Directory.Name
    if (-not $q.res) {
        if ($n -match '(?i)2160p|\b4k\b|\buhd\b') { $q.res = 2160 }
        elseif ($n -match '(?i)1080[pi]') { $q.res = 1080 }
        elseif ($n -match '(?i)720p') { $q.res = 720 }
        elseif ($n -match '(?i)480p|576p|dvdrip|\bdvd\b|xvid|divx|sdtv') { $q.res = 480 }
    }
    if (-not $q.channels) {
        if ($n -match '(?<![0-9])7[ ._]1(?![0-9])') { $q.channels = 8 }
        elseif ($n -match '(?<![0-9])5[ ._]1(?![0-9])|\bAC3\b|\bDTS\b|\bDD\b|TrueHD|Atmos') { $q.channels = 6 }
        elseif ($n -match '(?<![0-9])2[ ._]0(?![0-9])|\bstereo\b') { $q.channels = 2 }
    }
    if (-not $q.hdr) { $q.hdr = $n -match '(?i)\bHDR|\bDV\b|dolby.?vision' }
    $obj = [pscustomobject]$q
    $script:Cache[$key] = $obj
    return $obj
}

function Score($q, $size) {
    $order = if ($Prefer4K) { @{ 2160 = 5; 1080 = 4; 720 = 3; 480 = 2; 0 = 1 } } else { @{ 1080 = 5; 2160 = 4; 720 = 3; 480 = 2; 0 = 1 } }
    $res = $order[[int]$q.res]; if (-not $res) { $res = 1 }
    $ch = if ($q.channels -ge 6) { 3 } elseif ($q.channels -ge 2) { 2 } elseif ($q.channels -ge 1) { 1 } else { 0 }
    return [double]$res * 1e15 + [double]$ch * 1e14 + [double]$size
}

function Quality-Label($q) {
    $r = if ($q.res) { "$($q.res)p" } else { "?p" }
    $c = switch ([int]$q.channels) { 8 { "7.1" } 6 { "5.1" } 2 { "2.0" } 1 { "mono" } 0 { "?" } default { "$($q.channels)ch" } }
    $h = if ($q.hdr) { " HDR" } else { "" }
    return "$r $c$h"
}

function Name-Score($it) {
    # How well a file is named: title + year / SxxEyy in the file name itself beats "copy of ep2.mkv".
    $n = $it.file.Name; $sc = 0
    if ($n -match '(19|20)\d{2}|S\d{1,2}E\d{1,3}') { $sc += 2 }
    if ($it.title -and (Norm-Key $n).Contains((Norm-Key $it.title))) { $sc += 1 }
    if ($n -notmatch '(?i)copy|\(\d\)\.') { $sc += 1 }
    return $sc
}

function Quick-Hash($path, $size) {
    # Hash of the first and last 1 MB plus the size: tells true byte-for-byte copies apart fast.
    $fs = [IO.File]::OpenRead($path)
    try {
        $n = [int][math]::Min(1MB, $size)
        $buf = New-Object byte[] ($n * 2)
        [void]$fs.Read($buf, 0, $n)
        if ($size -gt $n) { [void]$fs.Seek(-$n, [IO.SeekOrigin]::End); [void]$fs.Read($buf, $n, $n) }
        $sha = [Security.Cryptography.SHA1]::Create()
        return ([BitConverter]::ToString($sha.ComputeHash($buf)) -replace '-', '') + "-$size"
    } finally { $fs.Dispose() }
}

# ------------------------------------------------------------------ scanning

function Find-Videos($root) {
    $out = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($root)
    while ($stack.Count) {
        $dir = $stack.Pop()
        try { $entries = [IO.Directory]::EnumerateFileSystemEntries($dir) } catch { continue }
        foreach ($e in $entries) {
            try {
                $attr = [IO.File]::GetAttributes($e)
                if ($attr -band [IO.FileAttributes]::Directory) {
                    $name = [IO.Path]::GetFileName($e)
                    if ($SkipDirs -contains $name -or $name.StartsWith(".")) { continue }
                    if ($attr -band [IO.FileAttributes]::ReparsePoint) { continue }
                    $stack.Push($e)
                } elseif ($VideoExt -contains [IO.Path]::GetExtension($e).ToLower()) {
                    $f = New-Object IO.FileInfo $e
                    if ($f.Name -match '(?i)(^|[ ._-])(sample|trailer)([ ._-]|$)') { continue }
                    $out.Add($f)
                }
            } catch { }
        }
    }
    return $out
}

function Scan($roots) {
    Load-Cache
    if (-not $script:HaveProbe) { Warn "FFmpeg not found: reading quality from file names. For exact info: winget install Gyan.FFmpeg" }
    $files = @()
    foreach ($r in $roots) {
        Say "Scanning $r ..."
        $found = Find-Videos $r
        Say "  $($found.Count) video file(s)"
        $files += $found
    }
    $items = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($f in $files) {
        $i++
        if ($i % 25 -eq 0) { Write-Progress -Activity "Reading video info" -Status "$i of $($files.Count)" -PercentComplete ($i * 100 / $files.Count) }
        $d = Describe-Name $f
        $q = Get-Quality $f
        if ($d.kind -eq "tv") {
            $key = "tv|" + (Norm-Key $d.title) + "|S{0:D2}{1}" -f $d.season, $d.episode
            $label = "{0} S{1:D2}{2}" -f $d.title, $d.season, $d.episode
        } else {
            $key = "movie|" + (Norm-Key $d.title) + "|" + $d.year + "|" + $d.extra
            $label = if ($d.year) { "$($d.title) ($($d.year))" } else { $d.title }
            if ($d.extra) { $label += " [$($d.extra)]" }
        }
        $items.Add([pscustomobject]@{
            file = $f; path = $f.FullName; size = $f.Length; kind = $d.kind; title = $d.title; year = $d.year
            season = $d.season; episode = $d.episode; key = $key; label = $label; quality = $q
            score = (Score $q $f.Length); hash = ""; keep = $true; reason = ""
        })
    }
    Write-Progress -Activity "Reading video info" -Completed
    Save-Cache

    # Byte-for-byte copies (same size first, then a quick hash), whatever they're named:
    # put them in the same group as the copy that has a proper name.
    foreach ($g in ($items | Group-Object size | Where-Object { $_.Count -gt 1 })) {
        foreach ($it in $g.Group) { try { $it.hash = Quick-Hash $it.path $it.size } catch { } }
        foreach ($h in ($g.Group | Where-Object { $_.hash } | Group-Object hash | Where-Object { $_.Count -gt 1 })) {
            $anchor = $h.Group | Sort-Object -Property @{ Expression = { Name-Score $_ }; Descending = $true } | Select-Object -First 1
            foreach ($it in $h.Group) {
                $it.key = $anchor.key
                if (-not $it.title) { $it.title = $anchor.title; $it.label = $anchor.label; $it.kind = $anchor.kind }
            }
        }
    }
    # Same movie / same episode: keep the best copy (ties go to the better-named file), mark the rest.
    foreach ($g in @($items | Where-Object { $_.title } | Group-Object key | Where-Object { $_.Count -gt 1 })) {
        $best = $g.Group | Sort-Object -Property @{ Expression = { $_.score }; Descending = $true }, @{ Expression = { Name-Score $_ }; Descending = $true } | Select-Object -First 1
        foreach ($it in $g.Group) {
            if ($it -eq $best) { continue }
            $it.keep = $false
            $it.reason = if ($it.hash -and $it.hash -eq $best.hash) { "identical copy of $($best.path)" } else { "worse than $(Quality-Label $best.quality) copy at $($best.path)" }
        }
    }
    return $items
}

function Write-Report($items) {
    $out = Join-Path (Get-Location) "library-report.csv"
    $items | Sort-Object kind, label, @{ Expression = { $_.score }; Descending = $true } | ForEach-Object {
        [pscustomobject]@{
            Action = if ($_.keep) { "KEEP" } else { "EXTRA" }
            Type = $_.kind; Title = $_.label; Quality = (Quality-Label $_.quality); Size = (Size $_.size)
            Path = $_.path; Why = $_.reason
        }
    } | Export-Csv -Path $out -NoTypeInformation -Encoding UTF8
    return $out
}

function Summary($items) {
    $movies = @($items | Where-Object { $_.kind -eq "movie" -and $_.keep })
    $eps = @($items | Where-Object { $_.kind -eq "tv" -and $_.keep })
    $extra = @($items | Where-Object { -not $_.keep })
    $shows = @($eps | ForEach-Object { Norm-Key $_.title } | Sort-Object -Unique)
    $saved = ($extra | Measure-Object size -Sum).Sum
    Say ""
    Say "  Movies         : $($movies.Count)"
    Say "  TV             : $($shows.Count) show(s), $($eps.Count) episode(s)"
    Say "  Extra copies   : $($extra.Count)  ($(Size ([double]$saved)) you can free up)"
    $unknown = @($items | Where-Object { -not $_.title })
    if ($unknown.Count) { Say "  Unrecognized   : $($unknown.Count) file(s) (left alone)" }
    if ($extra.Count) {
        Say ""
        Say "Some of the extra copies:" Cyan
        foreach ($e in ($extra | Sort-Object size -Descending | Select-Object -First 12)) {
            Say ("  {0,-45} {1,-12} {2,9}  {3}" -f ($e.label.Substring(0, [math]::Min(45, $e.label.Length))), (Quality-Label $e.quality), (Size $e.size), $e.path)
        }
        if ($extra.Count -gt 12) { Say "  ... and $($extra.Count - 12) more (see the report)" }
    }
}

# ------------------------------------------------------------------ moving, with a log for undo

function New-Log($action) {
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $script:LogPath = Join-Path $LogDir ("{0:yyyyMMdd-HHmmss}-{1}.csv" -f (Get-Date), $action)
    "From,To" | Set-Content $script:LogPath -Encoding UTF8
}

function Move-Logged($from, $to) {
    $dir = Split-Path $to -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path -LiteralPath $to) {
        $base = [IO.Path]::Combine($dir, [IO.Path]::GetFileNameWithoutExtension($to))
        $ext = [IO.Path]::GetExtension($to); $n = 2
        while (Test-Path -LiteralPath "$base ($n)$ext") { $n++ }
        $to = "$base ($n)$ext"
    }
    Move-Item -LiteralPath $from -Destination $to
    ('"{0}","{1}"' -f $from.Replace('"', '""'), $to.Replace('"', '""')) | Add-Content $script:LogPath -Encoding UTF8
}

function Sidecars($video, $folderToo) {
    # Subtitles/.nfo/artwork that belong to this video: same name, or (when the
    # folder holds only this one video) everything in its folder and a Subs folder.
    $stem = [IO.Path]::GetFileNameWithoutExtension($video.Name)
    $dir = $video.Directory
    $list = @(Get-ChildItem -LiteralPath $dir.FullName -File | Where-Object {
        $SideExt -contains $_.Extension.ToLower() -and ($folderToo -or $_.Name.StartsWith($stem + ".") -or $_.Name.StartsWith($stem + "-"))
    })
    if ($folderToo) {
        foreach ($sub in @(Get-ChildItem -LiteralPath $dir.FullName -Directory | Where-Object { $_.Name -match '(?i)^subs?$|^subtitles$' })) {
            $list += @(Get-ChildItem -LiteralPath $sub.FullName -File -Recurse | Where-Object { $SideExt -contains $_.Extension.ToLower() })
        }
    }
    return $list
}

function Only-Video($file) {
    return @(Get-ChildItem -LiteralPath $file.DirectoryName -File | Where-Object { $VideoExt -contains $_.Extension.ToLower() }).Count -eq 1
}

function Remove-EmptyDirs($dir, $roots) {
    # Walk up from where a file used to be and remove folders left with nothing useful in them.
    $d = Get-Item -LiteralPath $dir -ErrorAction SilentlyContinue
    while ($d -and ($roots | Where-Object { $_.TrimEnd("\") -ieq $d.FullName.TrimEnd("\") }).Count -eq 0) {
        $left = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -Force -File | Where-Object { $_.Extension -notmatch '(?i)^\.(txt|nfo|url|jpg|png|exe|sfv|md5|db|ini)$' })
        if ($left.Count) { break }
        $parent = $d.Parent
        Remove-Item -LiteralPath $d.FullName -Recurse -Force
        $d = $parent
    }
}

function Confirm($question) {
    if ($Yes) { return $true }
    $a = (Read-Host "$question [y/N]").Trim().ToLower()
    return $a.StartsWith("y")
}

function Dup-Path($path) {
    # X:\Movies\Heat (1995)\heat.mkv  ->  X:\_Duplicates\Movies\Heat (1995)\heat.mkv  (same drive = instant move)
    $root = [IO.Path]::GetPathRoot($path)
    return Join-Path (Join-Path $root $DupFolder) $path.Substring($root.Length)
}

function Do-Dedupe($items, $roots) {
    $extra = @($items | Where-Object { -not $_.keep })
    if (-not $extra.Count) { Good "No duplicates. Nothing to do."; return }
    Say ""
    Say "This moves $($extra.Count) extra copies ($(Size ([double](($extra | Measure-Object size -Sum).Sum)))) into a '$DupFolder' folder on their own drive." Cyan
    Say "Nothing is deleted. Check them, then run 'library purge' to delete them, or 'library undo' to put them back."
    if (-not (Confirm "Go ahead?")) { Say "Nothing changed."; return }
    New-Log "dedupe"
    $n = 0
    foreach ($e in $extra) {
        try {
            $folderToo = $false   # leave shared artwork/.nfo with the copy you're keeping
            foreach ($s in (Sidecars $e.file $folderToo)) { Move-Logged $s.FullName (Dup-Path $s.FullName) }
            Move-Logged $e.path (Dup-Path $e.path)
            Remove-EmptyDirs $e.file.DirectoryName $roots
            $n++
        } catch { Warn "Couldn't move $($e.path): $($_.Exception.Message)" }
    }
    Good "Moved $n extra copies into $DupFolder folders."
    Say "Undo with:  library undo"
}

function Target-For($it, $dest) {
    if ($it.kind -eq "tv") {
        $show = $it.title; if ($it.year) { $show = "$show ($($it.year))" }
        $show = ($show -replace '[<>:"/\\|?*]', '').Trim()
        $season = if ($it.season -eq 0) { "Specials" } else { "Season {0:D2}" -f $it.season }
        return Join-Path (Join-Path (Join-Path (Join-Path $dest "TV") $show) $season) $it.file.Name
    }
    $folder = $it.title; if ($it.year) { $folder = "$folder ($($it.year))" }
    $folder = ($folder -replace '[<>:"/\\|?*]', '').Trim()
    return Join-Path (Join-Path (Join-Path $dest "Movies") $folder) $it.file.Name
}

function Do-Consolidate($items, $roots) {
    if (-not $To) { Fail "Where to?  Example:  library consolidate D: E: F: -To G:" }
    $dest = Normalize-Path $To
    $keep = @($items | Where-Object { $_.keep -and $_.title })
    # Same-show folder name for every episode, whatever each file called it.
    $names = @{}
    foreach ($it in ($keep | Where-Object { $_.kind -eq "tv" })) {
        $k = Norm-Key $it.title
        if (-not $names.ContainsKey($k)) { $names[$k] = $it } elseif (-not $it.title.Contains(".") -and $it.title.Length -gt $names[$k].title.Length) { $names[$k] = $it }
    }
    foreach ($it in ($keep | Where-Object { $_.kind -eq "tv" })) {
        $first = $names[(Norm-Key $it.title)]; $it.title = $first.title; if ($first.year) { $it.year = $first.year }
    }
    $moves = @($keep | ForEach-Object { [pscustomobject]@{ item = $_; to = (Target-For $_ $dest) } } | Where-Object { $_.item.path -ine $_.to })
    if (-not $moves.Count) { Good "Everything is already in place."; return }
    $destRoot = [IO.Path]::GetPathRoot($dest)
    $crossing = @($moves | Where-Object { [IO.Path]::GetPathRoot($_.item.path) -ine $destRoot })
    $need = [double](($crossing | Measure-Object { $_.item.size } -Sum).Sum)
    $free = [double](New-Object IO.DriveInfo $destRoot).AvailableFreeSpace
    $extra = @($items | Where-Object { -not $_.keep }).Count
    Say ""
    Say "This moves $($moves.Count) file(s) into $dest\Movies and $dest\TV." Cyan
    Say "  Copying from other drives: $(Size $need)   Free on $destRoot : $(Size $free)"
    if ($extra) { Say "  $extra extra copies are left where they are (run 'library dedupe' first to set them aside)." }
    if ($need -gt $free - 5GB) { Fail "Not enough space on $destRoot. Free some up, or dedupe first, or pick a bigger drive." }
    if (-not (Confirm "Go ahead? (big libraries take hours; you can stop with Ctrl+C and run it again later)")) { Say "Nothing changed."; return }
    New-Log "consolidate"
    $n = 0; $i = 0
    foreach ($m in $moves) {
        $i++
        $it = $m.item
        Write-Progress -Activity "Moving to $dest" -Status "$i of $($moves.Count): $($it.label)" -PercentComplete ($i * 100 / $moves.Count)
        try {
            $folderToo = Only-Video $it.file
            $targetDir = Split-Path $m.to -Parent
            foreach ($s in (Sidecars $it.file $folderToo)) {
                $rel = $s.FullName.Substring($it.file.DirectoryName.Length).TrimStart("\", "/")
                Move-Logged $s.FullName (Join-Path $targetDir $rel)
            }
            Move-Logged $it.path $m.to
            Remove-EmptyDirs $it.file.DirectoryName $roots
            $n++
        } catch { Warn "Couldn't move $($it.path): $($_.Exception.Message)" }
    }
    Write-Progress -Activity "Moving" -Completed
    Good "Moved $n file(s). Your library is in $dest\Movies and $dest\TV."
    Say "Next: in Radarr use Movies > Library Import on $dest\Movies, and in Sonarr Series > Library Import on $dest\TV."
    Say "They'll match everything to the online databases, and can rename the files and add posters and info."
    Say "Undo with:  library undo"
}

function Do-Purge($roots) {
    $dirs = @($roots | ForEach-Object { Join-Path ([IO.Path]::GetPathRoot($_)) $DupFolder } | Sort-Object -Unique | Where-Object { Test-Path -LiteralPath $_ })
    if (-not $dirs.Count) { Good "No $DupFolder folders found."; return }
    Say "These will be deleted for good (they don't go to the Recycle Bin):" Red
    $total = 0
    foreach ($d in $dirs) {
        $sz = [double]((Get-ChildItem -LiteralPath $d -Recurse -File -Force | Measure-Object Length -Sum).Sum)
        $total += $sz
        Say "  $d  ($(Size $sz))"
    }
    $a = Read-Host "Type DELETE to delete $(Size $total)"
    if ($a -cne "DELETE") { Say "Nothing deleted."; return }
    foreach ($d in $dirs) { Remove-Item -LiteralPath $d -Recurse -Force; Good "Deleted $d" }
}

function Do-Undo {
    $log = Get-ChildItem -LiteralPath $LogDir -Filter "*.csv" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '-undone' } | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $log) { Say "Nothing to undo."; return }
    $rows = @(Import-Csv $log.FullName)
    Say "Putting back $($rows.Count) file(s) moved on $($log.LastWriteTime) ($($log.BaseName))." Cyan
    if (-not (Confirm "Go ahead?")) { return }
    [array]::Reverse($rows)
    $n = 0
    foreach ($r in $rows) {
        if (-not (Test-Path -LiteralPath $r.To)) { Warn "Gone: $($r.To)"; continue }
        if (Test-Path -LiteralPath $r.From) { Warn "Something is already at $($r.From); left $($r.To) where it is"; continue }
        $dir = Split-Path $r.From -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Move-Item -LiteralPath $r.To -Destination $r.From
        $n++
    }
    Rename-Item -LiteralPath $log.FullName -NewName ($log.BaseName + "-undone.csv")
    Good "Put back $n file(s)."
}

# ------------------------------------------------------------------ main

switch ($Command.ToLower()) {
    "scan" {
        $roots = Get-Roots; $items = Scan $roots; Summary $items
        $r = Write-Report $items
        Say ""; Good "Full list (open in Excel): $r"
        Say "Nothing was changed. Next:  library dedupe $($roots -join ' ')"
    }
    "dedupe" { $roots = Get-Roots; $items = Scan $roots; Summary $items; [void](Write-Report $items); Do-Dedupe $items $roots }
    "consolidate" { $roots = Get-Roots; $items = Scan $roots; Summary $items; [void](Write-Report $items); Do-Consolidate $items $roots }
    "purge" { Do-Purge (Get-Roots) }
    "undo" { Do-Undo }
    default {
        Say "library scan D: E: F:                report: what you have and what's duplicated (changes nothing)"
        Say "library dedupe D: E: F:              move extra copies into X:\_Duplicates (nothing deleted)"
        Say "library consolidate D: E: F: -To G:  gather the best copies into G:\Movies and G:\TV"
        Say "library purge D: E: F:               delete the _Duplicates folders for good (asks you to type DELETE)"
        Say "library undo                         put back what the last dedupe/consolidate moved"
        Say ""
        Say "Options: -Prefer4K (rank 4K above 1080p)  -Yes (don't ask before moving)"
        Say "Leave out the drives to pick them from a list."
    }
}
