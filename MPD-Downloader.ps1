param(
    [string]$Root = $PSScriptRoot,
    [int]$BrowserPollSeconds = 0.5,
    [int]$ParallelDownloads = 10
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = (Resolve-Path -LiteralPath $Root).Path
$ParallelDownloads = [Math]::Max(1, $ParallelDownloads)
$HtmlDir = Join-Path $Root 'html'
$MpdDir = Join-Path $Root 'mpd'
$Mp4Dir = Join-Path $Root 'mp4'
$ListPath = Join-Path $Root 'mpd-list.txt'

New-Item -ItemType Directory -Force -Path $HtmlDir, $MpdDir, $Mp4Dir | Out-Null

$script:BrowserPort = $null
$script:BrowserProfileDir = Join-Path $HtmlDir '.browser-profile'
$script:OpenEmbedTabs = @()

function Convert-QuotedPrintableText {
    param([string]$Text)

    $withoutSoftBreaks = [regex]::Replace($Text, "=\r?\n", '')
    return [regex]::Replace($withoutSoftBreaks, '=([0-9A-Fa-f]{2})', {
        param($Match)
        [char][Convert]::ToInt32($Match.Groups[1].Value, 16)
    })
}

function Get-MhtmlPartText {
    param(
        [string]$MhtmlText,
        [string]$ContentLocation
    )

    $pattern = "(?smi)^Content-Location:\s*$([regex]::Escape($ContentLocation))\s*\r?\n(?<rest>.*?)(?=^------|\z)"
    $match = [regex]::Match($MhtmlText, $pattern)
    if (-not $match.Success) {
        return $null
    }

    $rest = $match.Groups['rest'].Value
    $bodyStart = [regex]::Match($rest, "\r?\n\r?\n")
    if ($bodyStart.Success) {
        $rest = $rest.Substring($bodyStart.Index + $bodyStart.Length)
    }

    return Convert-QuotedPrintableText $rest
}

function Get-VideoIdFromEmbedUrl {
    param([string]$Url)

    $match = [regex]::Match($Url, '/videos/(?<id>[^/]+)/embed\.html', 'IgnoreCase')
    if ($match.Success) {
        return $match.Groups['id'].Value
    }

    return $null
}

function Get-EmbedUrlsFromMhtml {
    param([string]$MhtmlText)

    $matches = [regex]::Matches(
        $MhtmlText,
        'https://dev\.epicgames\.com/community/api/cms/videos/[^/\s"<>]+/embed\.html',
        'IgnoreCase'
    )

    $seen = @{}
    foreach ($match in $matches) {
        $url = $match.Value
        if (-not $seen.ContainsKey($url)) {
            $seen[$url] = $true
            $url
        }
    }
}

function Get-RemoteText {
    param([string]$Url)

    try {
        $headers = @{
            'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125 Safari/537.36'
            'Accept' = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
        }

        return (Invoke-WebRequest -Uri $Url -UseBasicParsing -Headers $headers -ErrorAction Stop).Content
    }
    catch {
        Write-Warning "Cannot fetch $Url. $($_.Exception.Message)"
        return $null
    }
}

function Get-LocalEmbedHtml {
    param([string]$VideoId)

    $expectedFile = Join-Path $HtmlDir "$VideoId.html"
    if (Test-Path -LiteralPath $expectedFile) {
        Write-Host "Using local embed HTML: $expectedFile"
        return Get-Content -LiteralPath $expectedFile -Raw
    }

    $files = Get-ChildItem -LiteralPath $HtmlDir -Filter '*.html' -File -Recurse -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        try {
            $text = Get-Content -LiteralPath $file.FullName -Raw
        }
        catch {
            continue
        }

        if ($text -match "/videos/$([regex]::Escape($VideoId))/embed\.html") {
            Write-Host "Using local embed HTML: $($file.FullName)"
            return $text
        }
    }

    return $null
}

function Get-BrowserPath {
    $commands = @('msedge', 'chrome')
    foreach ($command in $commands) {
        $found = Get-Command $command -ErrorAction SilentlyContinue
        if ($found) {
            return $found.Source
        }
    }

    $paths = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )

    foreach ($path in $paths) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }

    return $null
}

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        return $listener.LocalEndpoint.Port
    }
    finally {
        $listener.Stop()
    }
}

function Wait-DevTools {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            return Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -ErrorAction Stop
        }
        catch {
            Start-Sleep -Milliseconds 500
        }
    }

    throw "Browser DevTools did not start on port $Port."
}

function Get-DevToolsPage {
    param(
        [int]$Port,
        [string]$Url
    )

    $videoId = Get-VideoIdFromEmbedUrl $Url
    $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -ErrorAction Stop
    $page = $targets | Where-Object {
        $_.type -eq 'page' -and $_.url -like "*dev.epicgames.com/community/api/cms/videos/$videoId/embed.html*"
    } | Select-Object -First 1

    if (-not $page) {
        Open-DevToolsUrl -Port $Port -Url $Url
        Start-Sleep -Seconds 2
        $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -ErrorAction Stop
        $page = $targets | Where-Object {
            $_.type -eq 'page' -and $_.url -like "*dev.epicgames.com/community/api/cms/videos/$videoId/embed.html*"
        } | Select-Object -First 1
    }

    return $page
}

function Close-DevToolsPage {
    param(
        [int]$Port,
        [string]$TargetId
    )

    if ([string]::IsNullOrWhiteSpace($TargetId)) {
        return
    }

    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/close/$TargetId" -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
    }
}

function Add-OpenEmbedTab {
    param(
        [int]$Port,
        [string]$TargetId
    )

    if ([string]::IsNullOrWhiteSpace($TargetId)) {
        return
    }

    $script:OpenEmbedTabs += [pscustomobject]@{
        Port = $Port
        TargetId = $TargetId
    }
}

function Close-OpenEmbedTabs {
    foreach ($tab in $script:OpenEmbedTabs) {
        Close-DevToolsPage -Port $tab.Port -TargetId $tab.TargetId
    }

    $script:OpenEmbedTabs = @()
}

function Open-DevToolsUrl {
    param(
        [int]$Port,
        [string]$Url
    )

    $escapedUrl = [System.Uri]::EscapeDataString($Url)
    $devToolsUrl = "http://127.0.0.1:$Port/json/new?$escapedUrl"

    try {
        Invoke-RestMethod -Method Put -Uri $devToolsUrl -ErrorAction Stop | Out-Null
    }
    catch {
        Invoke-RestMethod -Uri $devToolsUrl -ErrorAction SilentlyContinue | Out-Null
    }
}

function Test-ForbiddenOrChallengeHtml {
    param([string]$Html)

    if ([string]::IsNullOrWhiteSpace($Html)) {
        return $true
    }

    return $Html -match '(?i)(403 Forbidden|Enable JavaScript and cookies to continue|cf_challenge|cf-challenge|Just a moment|security check to continue)'
}

function Receive-WebSocketText {
    param([System.Net.WebSockets.ClientWebSocket]$Socket)

    $buffer = New-Object byte[] 65536
    $stream = New-Object System.IO.MemoryStream

    do {
        $segment = [ArraySegment[byte]]::new($buffer)
        $result = $Socket.ReceiveAsync($segment, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        if ($result.Count -gt 0) {
            $stream.Write($buffer, 0, $result.Count)
        }
    } while (-not $result.EndOfMessage)

    return [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
}

function Invoke-CdpCommand {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [int]$Id,
        [string]$Method,
        [hashtable]$Params = @{}
    )

    $message = @{
        id = $Id
        method = $Method
        params = $Params
    } | ConvertTo-Json -Depth 20 -Compress

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($message)
    $segment = [ArraySegment[byte]]::new($bytes)
    $Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

    do {
        $responseText = Receive-WebSocketText $Socket
        $response = $responseText | ConvertFrom-Json
    } while ($response.id -ne $Id)

    return $response
}

function Get-PageHtml {
    param($Page)

    if (-not $Page -or -not $Page.webSocketDebuggerUrl) {
        throw 'Cannot find the opened embed page in browser DevTools.'
    }

    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    try {
        $socket.ConnectAsync([Uri]$Page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

        $response = Invoke-CdpCommand -Socket $socket -Id 1 -Method 'Runtime.evaluate' -Params @{
            expression = 'document.documentElement.outerHTML'
            returnByValue = $true
        }

        return [string]$response.result.result.value
    }
    finally {
        $socket.Dispose()
    }
}

function Save-EmbedHtmlFromBrowser {
    param(
        [string]$Url,
        [string]$HtmlPath
    )

    $browserPath = Get-BrowserPath
    if (-not $browserPath) {
        Write-Warning 'Cannot find Microsoft Edge or Google Chrome.'
        return $null
    }

    if (-not $script:BrowserPort) {
        $script:BrowserPort = Get-FreeTcpPort
        New-Item -ItemType Directory -Force -Path $script:BrowserProfileDir | Out-Null

        $arguments = @(
            "--remote-debugging-port=$($script:BrowserPort)",
            "--user-data-dir=$($script:BrowserProfileDir)",
            '--no-first-run',
            '--new-window',
            $Url
        )

        Start-Process -FilePath $browserPath -ArgumentList $arguments | Out-Null
        Wait-DevTools -Port $script:BrowserPort | Out-Null
    }
    else {
        Open-DevToolsUrl -Port $script:BrowserPort -Url $Url
    }

    Write-Host "Opening browser for: $Url"
    Write-Host "Waiting for the embed page. Checking every $BrowserPollSeconds seconds..."

    $page = $null
    $attempt = 0

    while ($true) {
        $attempt++
        Start-Sleep -Seconds $BrowserPollSeconds

        try {
            $page = Get-DevToolsPage -Port $script:BrowserPort -Url $Url
            $html = Get-PageHtml $page
        }
        catch {
            Write-Warning "Cannot read browser tab yet. $($_.Exception.Message)"
            continue
        }

        if (Get-QsepUrl @($html)) {
            [System.IO.File]::WriteAllText($HtmlPath, $html, [System.Text.UTF8Encoding]::new($false))
            Write-Host "Saved embed HTML: $(Split-Path -Leaf $HtmlPath)"
            Add-OpenEmbedTab -Port $script:BrowserPort -TargetId $page.id
            return $html
        }

        if (Test-ForbiddenOrChallengeHtml $html) {
            Write-Host "Still blocked/challenge for $(Split-Path -Leaf $HtmlPath). Waiting... attempt $attempt"
            continue
        }

        # Write-Host "Embed page loaded but qsep videoUrl is not visible yet. Waiting... attempt $attempt"
    }
}

function Get-QsepUrl {
    param([string[]]$HtmlCandidates)

    foreach ($html in $HtmlCandidates) {
        if ([string]::IsNullOrWhiteSpace($html)) {
            continue
        }

        $decodedHtml = [System.Net.WebUtility]::HtmlDecode($html)
        $match = [regex]::Match($decodedHtml, 'qsep://[^"''<>\s\\]+', 'IgnoreCase')
        if ($match.Success) {
            return $match.Value
        }
    }

    return $null
}

function Find-PlaylistValue {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        return $null
    }

    $playlistProperty = $Value.PSObject.Properties['playlist']
    if ($playlistProperty -and $playlistProperty.Value) {
        return [string]$playlistProperty.Value
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) {
            $found = Find-PlaylistValue $item
            if ($found) {
                return $found
            }
        }
    }

    foreach ($property in $Value.PSObject.Properties) {
        $found = Find-PlaylistValue $property.Value
        if ($found) {
            return $found
        }
    }

    return $null
}

function Decode-Base64Text {
    param([string]$EncodedText)

    $base64 = $EncodedText.Trim()
    if ($base64.Contains(',')) {
        $base64 = $base64.Substring($base64.LastIndexOf(',') + 1)
    }

    $base64 = $base64.Replace('-', '+').Replace('_', '/')
    $remainder = $base64.Length % 4

    if ($remainder -eq 2) {
        $base64 += '=='
    }
    elseif ($remainder -eq 3) {
        $base64 += '='
    }
    elseif ($remainder -eq 1) {
        throw 'Invalid base64 playlist value.'
    }

    $bytes = [Convert]::FromBase64String($base64)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Save-MpdFromQsepUrl {
    param(
        [string]$QsepUrl,
        [string]$MpdPath
    )

    $jsonUrl = $QsepUrl -replace '^qsep://', 'https://'
    $jsonText = Get-RemoteText $jsonUrl
    if (-not $jsonText) {
        return $false
    }

    try {
        $json = $jsonText | ConvertFrom-Json
        $playlist = Find-PlaylistValue $json
        if (-not $playlist) {
            throw 'No playlist value found in JSON.'
        }

        $mpdText = Decode-Base64Text $playlist
        [System.IO.File]::WriteAllText($MpdPath, $mpdText, [System.Text.UTF8Encoding]::new($false))
        return $true
    }
    catch {
        Write-Warning "Cannot create MPD $MpdPath. $($_.Exception.Message)"
        return $false
    }
}

function Get-FileUrl {
    param([string]$Path)

    return ([System.Uri](Resolve-Path -LiteralPath $Path).Path).AbsoluteUri
}

function Format-FileSize {
    param([Nullable[long]]$Bytes)

    if ($null -eq $Bytes) {
        return 'not downloaded'
    }

    if ($Bytes -ge 1GB) {
        return '{0:N2} GB' -f ($Bytes / 1GB)
    }

    if ($Bytes -ge 1MB) {
        return '{0:N2} MB' -f ($Bytes / 1MB)
    }

    if ($Bytes -ge 1KB) {
        return '{0:N2} KB' -f ($Bytes / 1KB)
    }

    return "$Bytes bytes"
}

function Get-VideoSizeText {
    param([string]$Mp4Path)

    if (-not (Test-Path -LiteralPath $Mp4Path)) {
        return 'not downloaded'
    }

    $file = Get-Item -LiteralPath $Mp4Path
    return Format-FileSize $file.Length
}

function Add-MpdListEntry {
    param(
        [string]$MhtmlPath,
        [string]$EmbedUrl,
        [string]$Mp4Path
    )

    $mhtmlLink = Get-FileUrl $MhtmlPath
    $sizeText = Get-VideoSizeText $Mp4Path
    $line = "$mhtmlLink`t$EmbedUrl`t$sizeText"
    Add-Content -LiteralPath $ListPath -Value $line -Encoding UTF8
}

function Start-DownloadJob {
    param(
        [string]$YtDlpPath,
        [string]$MpdPath,
        [string]$Mp4Path
    )

    Start-Job -ArgumentList $YtDlpPath, $MpdPath, $Mp4Path -ScriptBlock {
        param(
            [string]$YtDlpPath,
            [string]$MpdPath,
            [string]$Mp4Path
        )

        $outputTemplate = Join-Path (Split-Path -Parent $Mp4Path) "$([System.IO.Path]::GetFileNameWithoutExtension($Mp4Path)).%(ext)s"
        $mpdUrl = ([System.Uri](Resolve-Path -LiteralPath $MpdPath).Path).AbsoluteUri

        & $YtDlpPath --enable-file-urls $mpdUrl -f 'bestvideo[height<=720]+bestaudio/best[height<=720]' --merge-output-format mp4 -o $outputTemplate
        if ($LASTEXITCODE -ne 0) {
            throw "yt-dlp failed with exit code $LASTEXITCODE for $Mp4Path"
        }
    }
}

function Invoke-ParallelDownloads {
    param(
        [object[]]$Tasks,
        [int]$MaxParallel
    )

    if (-not $Tasks -or $Tasks.Count -eq 0) {
        return
    }

    $ytDlp = Get-Command yt-dlp -ErrorAction SilentlyContinue
    if (-not $ytDlp) {
        Write-Warning 'yt-dlp was not found in PATH. MP4 downloads skipped.'
        return
    }

    Write-Host ""
    Write-Host "Downloading MP4 files max 720p with $MaxParallel parallel job(s)..."

    $running = @()
    $nextIndex = 0

    while ($nextIndex -lt $Tasks.Count -or $running.Count -gt 0) {
        while ($running.Count -lt $MaxParallel -and $nextIndex -lt $Tasks.Count) {
            $task = $Tasks[$nextIndex]
            $nextIndex++

            if (Test-Path -LiteralPath $task.Mp4Path) {
                Write-Host "Skipping MP4: $(Split-Path -Leaf $task.Mp4Path) already exists"
                continue
            }

            if (-not (Test-Path -LiteralPath $task.MpdPath)) {
                Write-Warning "MP4 skipped because $(Split-Path -Leaf $task.MpdPath) does not exist."
                continue
            }

            Write-Host "Starting MP4: $(Split-Path -Leaf $task.Mp4Path)"
            $job = Start-DownloadJob -YtDlpPath $ytDlp.Source -MpdPath $task.MpdPath -Mp4Path $task.Mp4Path
            $running += [pscustomobject]@{
                Job = $job
                Task = $task
            }
        }

        if ($running.Count -eq 0) {
            continue
        }

        $completedJob = Wait-Job -Job ($running.Job) -Any
        $completedTask = ($running | Where-Object { $_.Job.Id -eq $completedJob.Id } | Select-Object -First 1).Task
        try {
            Receive-Job -Job $completedJob -ErrorAction Stop
        }
        catch {
            Write-Warning $_.Exception.Message
        }

        if ($completedJob.State -eq 'Failed') {
            Write-Warning "Download failed: $(Split-Path -Leaf $completedTask.Mp4Path)"
        }
        else {
            Write-Host "Finished MP4: $(Split-Path -Leaf $completedTask.Mp4Path)"
        }

        Remove-Job -Job $completedJob
        $running = @($running | Where-Object { $_.Job.Id -ne $completedJob.Id })
    }
}

$listHeader = "mhtml_file`tembed_html`tvideo_size"
Set-Content -LiteralPath $ListPath -Value $listHeader -Encoding UTF8
$downloadTasks = @()
$listEntries = @()
$queuedMp4Paths = @{}

$excludedScanDirs = @($HtmlDir, $MpdDir, $Mp4Dir) | ForEach-Object {
    (Resolve-Path -LiteralPath $_).Path.TrimEnd('\') + '\'
}

$mhtmlFiles = Get-ChildItem -LiteralPath $Root -Filter '*.mhtml' -File -Recurse | Where-Object {
    $fullName = $_.FullName
    -not ($excludedScanDirs | Where-Object { $fullName.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) })
}
if (-not $mhtmlFiles) {
    Write-Host "No .mhtml files found in $Root"
    exit 0
}

foreach ($mhtmlFile in $mhtmlFiles) {
    Write-Host ""
    Write-Host "Scanning MHTML: $($mhtmlFile.Name)"
    $mhtmlText = Get-Content -LiteralPath $mhtmlFile.FullName -Raw
    $embedUrls = @(Get-EmbedUrlsFromMhtml $mhtmlText)

    if (-not $embedUrls) {
        Write-Host 'No Epic embed URLs found.'
        continue
    }

    foreach ($embedUrl in $embedUrls) {
        $videoId = Get-VideoIdFromEmbedUrl $embedUrl
        if (-not $videoId) {
            continue
        }

        $mpdPath = Join-Path $MpdDir "$videoId.mpd"
        $mp4Path = Join-Path $Mp4Dir "$videoId.mp4"
        $htmlPath = Join-Path $HtmlDir "$videoId.html"

        Write-Host ""
        Write-Host "Video: $videoId"

        if (Test-Path -LiteralPath $mpdPath) {
            Write-Host "Skipping MPD: $videoId.mpd already exists"
        }
        else {
            $embeddedHtml = Get-MhtmlPartText -MhtmlText $mhtmlText -ContentLocation $embedUrl
            $localHtml = Get-LocalEmbedHtml $videoId
            $qsepUrl = Get-QsepUrl @($embeddedHtml, $localHtml)

            if (-not $qsepUrl) {
                $browserHtml = Save-EmbedHtmlFromBrowser -Url $embedUrl -HtmlPath $htmlPath
                $qsepUrl = Get-QsepUrl @($browserHtml)
            }

            if (-not $qsepUrl) {
                Write-Warning "No qsep videoUrl found for $videoId. Try again after the embed page is fully loaded in the browser."
            }
            else {
                Write-Host "Saving MPD: $videoId.mpd"
                [void](Save-MpdFromQsepUrl -QsepUrl $qsepUrl -MpdPath $mpdPath)
            }
        }

        if (-not (Test-Path -LiteralPath $mpdPath)) {
            Write-Warning "MP4 skipped because $videoId.mpd does not exist."
        }
        else {
            $mp4Key = $mp4Path.ToLowerInvariant()
            if (-not $queuedMp4Paths.ContainsKey($mp4Key)) {
                $queuedMp4Paths[$mp4Key] = $true
                $downloadTasks += [pscustomobject]@{
                    MpdPath = $mpdPath
                    Mp4Path = $mp4Path
                }
            }
        }

        $listEntries += [pscustomobject]@{
            MhtmlPath = $mhtmlFile.FullName
            EmbedUrl = $embedUrl
            Mp4Path = $mp4Path
        }

        Close-OpenEmbedTabs
    }
}

Invoke-ParallelDownloads -Tasks $downloadTasks -MaxParallel $ParallelDownloads

foreach ($entry in $listEntries) {
    Add-MpdListEntry -MhtmlPath $entry.MhtmlPath -EmbedUrl $entry.EmbedUrl -Mp4Path $entry.Mp4Path
}

Write-Host ""
Write-Host 'Done.'
