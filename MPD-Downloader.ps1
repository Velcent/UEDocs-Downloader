param(
    [string]$Root = $PSScriptRoot,
    [int]$BrowserPollSeconds = 0.5,
    [int]$ParallelDownloads = 6,
    [int]$DownloadRetries = 100000,
    [switch]$SkipYoutubeVideo
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = (Resolve-Path -LiteralPath $Root).Path
$ParallelDownloads = [Math]::Max(1, $ParallelDownloads)
$DownloadRetries = [Math]::Max(0, $DownloadRetries)
$VideoDir = Join-Path $Root 'video'
$HtmlDir = Join-Path $VideoDir 'embed'
$MpdDir = Join-Path $VideoDir 'mpd'
$Mp4Dir = Join-Path $VideoDir 'mp4'
$OldMp4Dir = Join-Path $VideoDir 'old'
$ListPath = Join-Path $VideoDir 'mpd-list.tsv'

New-Item -ItemType Directory -Force -Path $VideoDir, $HtmlDir, $MpdDir, $Mp4Dir, $OldMp4Dir | Out-Null

$script:BrowserPort = $null
$script:BrowserProfileDir = Join-Path $Root '.browser-profile'
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

function Get-MhtmlPartTextByContentLocation {
    param(
        [string]$MhtmlText,
        [scriptblock]$Predicate
    )

    $pattern = "(?smi)^Content-Location:\s*(?<url>[^\r\n]+)\s*\r?\n(?<rest>.*?)(?=^------|\z)"
    foreach ($match in [regex]::Matches($MhtmlText, $pattern)) {
        $contentLocation = [System.Net.WebUtility]::HtmlDecode($match.Groups['url'].Value.Trim()).Replace('\/', '/')
        if (-not (& $Predicate $contentLocation)) {
            continue
        }

        $rest = $match.Groups['rest'].Value
        $bodyStart = [regex]::Match($rest, "\r?\n\r?\n")
        if ($bodyStart.Success) {
            $rest = $rest.Substring($bodyStart.Index + $bodyStart.Length)
        }

        return Convert-QuotedPrintableText $rest
    }

    return $null
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

function Get-YoutubeVideoIdFromUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $null
    }

    $decoded = [System.Net.WebUtility]::HtmlDecode($Url)
    $patterns = @(
        '(?i)(?:youtube(?:-nocookie)?\.com/(?:embed|shorts|live)/|youtu\.be/)(?<id>[A-Za-z0-9_-]{11})',
        '(?i)youtube(?:-nocookie)?\.com/.*?[?&]v=(?<id>[A-Za-z0-9_-]{11})'
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($decoded, $pattern)
        if ($match.Success) {
            return $match.Groups['id'].Value
        }
    }

    return $null
}

function Get-YoutubeEmbedUrlsFromMhtml {
    param([string]$MhtmlText)

    $searchText = [System.Net.WebUtility]::HtmlDecode((Convert-QuotedPrintableText $MhtmlText)).Replace('\/', '/')
    $patterns = @(
        'https?://(?:www\.)?youtube(?:-nocookie)?\.com/embed/[A-Za-z0-9_-]{11}[^"''<>\s\\)]*',
        'https?://(?:www\.)?youtube(?:-nocookie)?\.com/watch\?[^"''<>\s\\)]*?v=[A-Za-z0-9_-]{11}[^"''<>\s\\)]*',
        'https?://(?:www\.)?youtube(?:-nocookie)?\.com/shorts/[A-Za-z0-9_-]{11}[^"''<>\s\\)]*',
        'https?://(?:www\.)?youtube(?:-nocookie)?\.com/live/[A-Za-z0-9_-]{11}[^"''<>\s\\)]*',
        'https?://youtu\.be/[A-Za-z0-9_-]{11}[^"''<>\s\\)]*'
    )

    $seen = @{}
    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches($searchText, $pattern, 'IgnoreCase')) {
            $url = $match.Value.TrimEnd('&', '?')
            $videoId = Get-YoutubeVideoIdFromUrl $url
            if (-not $videoId) {
                continue
            }

            $canonicalUrl = "https://www.youtube.com/watch?v=$videoId"
            if (-not $seen.ContainsKey($canonicalUrl)) {
                $seen[$canonicalUrl] = $true
                $canonicalUrl
            }
        }
    }
}

function Get-YoutubeEmbedHtmlFromMhtml {
    param(
        [string]$MhtmlText,
        [string]$VideoId
    )

    return Get-MhtmlPartTextByContentLocation -MhtmlText $MhtmlText -Predicate {
        param([string]$ContentLocation)

        if ($ContentLocation -notmatch '(?i)(youtube|youtu\.be)') {
            return $false
        }

        return (Get-YoutubeVideoIdFromUrl $ContentLocation) -eq $VideoId
    }
}

function New-YoutubeEmbedHtml {
    param([string]$VideoId)

    $embedUrl = "https://www.youtube.com/embed/$VideoId"
    return @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<style>
html, body {
  width: 100%;
  height: 100%;
  margin: 0;
  background: #000;
}

iframe {
  width: 100%;
  height: 100%;
  border: 0;
}
</style>
</head>
<body>
<iframe src="$embedUrl" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen></iframe>
</body>
</html>
"@
}

function Get-YoutubeCoverImageUrl {
    param(
        [string]$Html,
        [string]$VideoId
    )

    if ([string]::IsNullOrWhiteSpace($Html) -or [string]::IsNullOrWhiteSpace($VideoId)) {
        return $null
    }

    $decodedHtml = [System.Net.WebUtility]::HtmlDecode($Html).
        Replace('\/', '/').
        Replace('\u0026', '&')
    $escapedVideoId = [regex]::Escape($VideoId)
    $patterns = @(
        ('https?://(?:i\.ytimg\.com|img\.youtube\.com)/(?:vi|vi_webp)/{0}/[^"''<>\s\\)]+' -f $escapedVideoId),
        ('https?://[^"''<>\s\\)]+ytimg\.com/[^"''<>\s\\)]*/{0}/[^"''<>\s\\)]+' -f $escapedVideoId)
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($decodedHtml, $pattern, 'IgnoreCase')
        if ($match.Success) {
            return $match.Value.TrimEnd(',', '.', ';')
        }
    }

    return $null
}

function Test-RemoteImageUrl {
    param([string]$Url)

    try {
        $response = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -ErrorAction Stop
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
            return $false
        }

        $contentType = $response.Headers['Content-Type']
        return (-not $contentType -or $contentType -match '^image/')
    }
    catch {
        return $false
    }
}

function Get-YoutubeOnlineCoverImageUrl {
    param([string]$VideoId)

    if ([string]::IsNullOrWhiteSpace($VideoId)) {
        return $null
    }

    $coverUrls = @(
        "https://i.ytimg.com/vi/$VideoId/maxresdefault.jpg",
        "https://i.ytimg.com/vi_webp/$VideoId/maxresdefault.webp",
        "https://i.ytimg.com/vi/$VideoId/hqdefault.jpg",
        "https://i.ytimg.com/vi_webp/$VideoId/hqdefault.webp",
        "https://i.ytimg.com/vi/$VideoId/mqdefault.jpg",
        "https://i.ytimg.com/vi/$VideoId/default.jpg"
    )

    foreach ($coverUrl in $coverUrls) {
        if (Test-RemoteImageUrl $coverUrl) {
            return $coverUrl
        }
    }

    return $null
}

function Add-YoutubeCoverImageUrlToHtml {
    param(
        [string]$Html,
        [string]$CoverUrl
    )

    if ([string]::IsNullOrWhiteSpace($Html) -or [string]::IsNullOrWhiteSpace($CoverUrl)) {
        return $Html
    }

    $encodedCoverUrl = [System.Net.WebUtility]::HtmlEncode($CoverUrl)
    $coverMeta = "<meta property=""og:image"" content=""$encodedCoverUrl"">"

    if ($Html -match '(?i)</head>') {
        return ([regex]::new('</head>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).
            Replace($Html, "$coverMeta`r`n</head>", 1)
    }

    return "$Html`r`n<!-- YouTube cover: $encodedCoverUrl -->"
}

function Save-YoutubeEmbedHtml {
    param(
        [string]$MhtmlText,
        [string]$VideoId,
        [string]$HtmlPath
    )

    if (Test-Path -LiteralPath $HtmlPath) {
        $existingHtml = [System.IO.File]::ReadAllText($HtmlPath)
        if (Get-YoutubeCoverImageUrl -Html $existingHtml -VideoId $VideoId) {
            Write-Host "Skipping embed HTML: $(Split-Path -Leaf $HtmlPath) already exists"
            return
        }

        Write-Host "Refreshing YouTube embed HTML without cover: $(Split-Path -Leaf $HtmlPath)"
    }

    $candidates = @()
    $mhtmlHtml = Get-YoutubeEmbedHtmlFromMhtml -MhtmlText $MhtmlText -VideoId $VideoId
    if (-not [string]::IsNullOrWhiteSpace($mhtmlHtml)) {
        $candidates += [pscustomobject]@{
            Source = 'MHTML'
            Html = $mhtmlHtml
            CoverUrl = Get-YoutubeCoverImageUrl -Html $mhtmlHtml -VideoId $VideoId
        }
    }

    if (-not $candidates -or -not ($candidates | Where-Object { $_.CoverUrl } | Select-Object -First 1)) {
        $onlineHtml = Get-RemoteText "https://www.youtube.com/embed/$VideoId"
        if (-not [string]::IsNullOrWhiteSpace($onlineHtml)) {
            $candidates += [pscustomobject]@{
                Source = 'online'
                Html = $onlineHtml
                CoverUrl = Get-YoutubeCoverImageUrl -Html $onlineHtml -VideoId $VideoId
            }
        }
    }

    $selected = $candidates | Where-Object { $_.CoverUrl } | Select-Object -First 1
    if (-not $selected) {
        $selected = $candidates | Select-Object -First 1
    }

    if ($selected) {
        $html = $selected.Html
        $coverUrl = $selected.CoverUrl
    }
    else {
        $html = New-YoutubeEmbedHtml -VideoId $VideoId
        $coverUrl = $null
    }

    if ([string]::IsNullOrWhiteSpace($coverUrl)) {
        Write-Host "YouTube cover not found in HTML. Checking online cover: $VideoId"
        $coverUrl = Get-YoutubeOnlineCoverImageUrl -VideoId $VideoId
        if (-not [string]::IsNullOrWhiteSpace($coverUrl)) {
            $html = Add-YoutubeCoverImageUrlToHtml -Html $html -CoverUrl $coverUrl
        }
    }

    [System.IO.File]::WriteAllText($HtmlPath, $html, [System.Text.UTF8Encoding]::new($false))
    if ($selected -and $selected.CoverUrl) {
        Write-Host "Saved YouTube embed HTML from $($selected.Source): $(Split-Path -Leaf $HtmlPath)"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($coverUrl)) {
        Write-Host "Saved YouTube embed HTML with online cover: $(Split-Path -Leaf $HtmlPath)"
    }
    else {
        Write-Host "Saved YouTube embed HTML without cover: $(Split-Path -Leaf $HtmlPath)"
    }
}

function Get-LocalMp4UrlsFromMhtml {
    param([string]$MhtmlText)

    $searchText = [System.Net.WebUtility]::HtmlDecode((Convert-QuotedPrintableText $MhtmlText)).Replace('\/', '/')
    $pattern = 'https://media\.local/assets/video/[^"''<>\s\\)]+\.mp4'
    $seen = @{}

    foreach ($match in [regex]::Matches($searchText, $pattern, 'IgnoreCase')) {
        $url = $match.Value
        if (-not $seen.ContainsKey($url)) {
            $seen[$url] = $true
            $url
        }
    }
}

function Get-LocalMp4VideoIdFromUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $null
    }

    $decoded = [System.Net.WebUtility]::HtmlDecode($Url).Replace('\/', '/')
    $match = [regex]::Match($decoded, 'https://media\.local/assets/video/(?<id>[^/"''<>\s\\)]+)\.mp4', 'IgnoreCase')
    if ($match.Success) {
        return $match.Groups['id'].Value
    }

    return $null
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

function Initialize-BrowserProfile {
    param([string]$ProfileDir)

    if (Test-Path -LiteralPath $ProfileDir) {
        return
    }

    $defaultProfileDir = Join-Path $ProfileDir 'Default'
    New-Item -ItemType Directory -Force -Path $defaultProfileDir | Out-Null

    $preferencesPath = Join-Path $defaultProfileDir 'Preferences'
    $localStatePath = Join-Path $ProfileDir 'Local State'

    $preferences = [ordered]@{
        background_mode = [ordered]@{
            enabled = $false
        }
        browser = [ordered]@{
            has_seen_welcome_page = $true
        }
        performance_tuning = [ordered]@{
            sleeping_tabs_enabled = $false
            tab_sleeping_enabled = $false
            fade_sleeping_tabs_enabled = $false
            efficiency_mode_enabled = $false
            sleeping_tabs = [ordered]@{
                enabled = $false
                fade_enabled = $false
            }
        }
    }

    $localState = [ordered]@{
        background_mode = [ordered]@{
            enabled = $false
        }
        browser = [ordered]@{
            enabled_labs_experiments = @()
        }
    }

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($preferencesPath, ($preferences | ConvertTo-Json -Depth 20 -Compress), $utf8NoBom)
    [System.IO.File]::WriteAllText($localStatePath, ($localState | ConvertTo-Json -Depth 20 -Compress), $utf8NoBom)
    Write-Host "Initialized browser profile: $ProfileDir"
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
        Initialize-BrowserProfile -ProfileDir $script:BrowserProfileDir

        $arguments = @(
            "--remote-debugging-port=$($script:BrowserPort)",
            "--user-data-dir=$($script:BrowserProfileDir)",
            '--disable-background-mode',
            '--disable-background-timer-throttling',
            '--disable-renderer-backgrounding',
            '--disable-features=msSleepingTabs,msSleepingTabsAvailable,msFadeSleepingTabs,msEdgeSleepingTabs,EdgeSleepingTabs,TabFreeze,TabDiscarding,AutomaticTabDiscarding,PerformanceDetector',
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

function Restore-Mp4FromOld {
    param([string]$Mp4Path)

    if (Test-Path -LiteralPath $Mp4Path) {
        return $true
    }

    $oldPath = Join-Path $OldMp4Dir (Split-Path -Leaf $Mp4Path)
    if (-not (Test-Path -LiteralPath $oldPath)) {
        return $false
    }

    try {
        Move-Item -LiteralPath $oldPath -Destination $Mp4Path
        Write-Host "Moved MP4 from old: $(Split-Path -Leaf $Mp4Path)"
        return $true
    }
    catch {
        Write-Warning "Cannot move MP4 from old: $(Split-Path -Leaf $Mp4Path). $($_.Exception.Message)"
        return $false
    }
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
    Sync-ListBackup -Path $ListPath
}

function Sync-ListBackup {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $backupPath = "$Path.bak"
    [System.IO.File]::Copy($Path, $backupPath, $true)
}

function Start-DownloadJob {
    param(
        [string]$YtDlpPath,
        [string]$Kind,
        [string]$MpdPath,
        [string]$SourceUrl,
        [string]$Mp4Path
    )

    Start-Job -ArgumentList $YtDlpPath, $Kind, $MpdPath, $SourceUrl, $Mp4Path -ScriptBlock {
        param(
            [string]$YtDlpPath,
            [string]$Kind,
            [string]$MpdPath,
            [string]$SourceUrl,
            [string]$Mp4Path
        )

        $outputTemplate = Join-Path (Split-Path -Parent $Mp4Path) "$([System.IO.Path]::GetFileNameWithoutExtension($Mp4Path)).%(ext)s"

        if ($Kind -eq 'youtube') {
            $ytDlpOutput = & $YtDlpPath $SourceUrl -f 'bestvideo[height<=720][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=720]+bestaudio/best[height<=720]' --merge-output-format mp4 -o $outputTemplate 2>&1
        }
        else {
            $mpdUrl = ([System.Uri](Resolve-Path -LiteralPath $MpdPath).Path).AbsoluteUri
            $ytDlpOutput = & $YtDlpPath --enable-file-urls $mpdUrl -f 'bestvideo[height<=720]+bestaudio/best[height<=720]' --merge-output-format mp4 -o $outputTemplate 2>&1
        }

        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $outputText = ($ytDlpOutput | ForEach-Object { $_.ToString() }) -join "`n"
            if ($Kind -eq 'youtube' -and $outputText -match 'ERROR:\s+\[youtube\]\s+[A-Za-z0-9_-]{11}:\s+Video unavailable') {
                return [pscustomobject]@{
                    Status = 'Skipped'
                    Reason = 'YouTube video unavailable'
                    ExitCode = $exitCode
                    Output = $outputText
                }
            }

            return [pscustomobject]@{
                Status = 'Failed'
                Reason = "yt-dlp failed with exit code $exitCode for $Mp4Path"
                ExitCode = $exitCode
                Output = $outputText
            }
        }

        return [pscustomobject]@{
            Status = 'Succeeded'
            Reason = $null
            ExitCode = 0
            Output = $null
        }
    }
}

function Invoke-ParallelDownloads {
    param(
        [object[]]$Tasks,
        [int]$MaxParallel,
        [int]$RetryLimit
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

            if (-not $task.PSObject.Properties['RetryCount']) {
                $task | Add-Member -NotePropertyName RetryCount -NotePropertyValue 0 -Force
            }

            if (Restore-Mp4FromOld -Mp4Path $task.Mp4Path) {
                Write-Host "Skipping MP4: $(Split-Path -Leaf $task.Mp4Path) already exists"
                continue
            }

            if ($task.Kind -ne 'youtube' -and -not (Test-Path -LiteralPath $task.MpdPath)) {
                Write-Warning "MP4 skipped because $(Split-Path -Leaf $task.MpdPath) does not exist."
                continue
            }

            $attempt = [int]$task.RetryCount + 1
            $totalAttempts = $RetryLimit + 1
            Write-Host "Starting MP4: $(Split-Path -Leaf $task.Mp4Path) (attempt $attempt/$totalAttempts)"
            $job = Start-DownloadJob -YtDlpPath $ytDlp.Source -Kind $task.Kind -MpdPath $task.MpdPath -SourceUrl $task.SourceUrl -Mp4Path $task.Mp4Path
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
        $downloadResult = $null
        try {
            $downloadResult = Receive-Job -Job $completedJob -ErrorAction Stop | Select-Object -Last 1
        }
        catch {
            Write-Warning $_.Exception.Message
        }

        if ($downloadResult -and $downloadResult.Status -eq 'Skipped') {
            Write-Warning "YouTube skipped: $(Split-Path -Leaf $completedTask.Mp4Path). $($downloadResult.Reason)"
        }
        elseif ($completedJob.State -eq 'Failed' -or ($downloadResult -and $downloadResult.Status -eq 'Failed')) {
            if ($downloadResult -and $downloadResult.Reason) {
                Write-Warning $downloadResult.Reason
            }

            if ((Test-Path -LiteralPath $completedTask.Mp4Path) -and (Get-Item -LiteralPath $completedTask.Mp4Path).Length -gt 0) {
                Write-Host "Finished MP4 despite warning: $(Split-Path -Leaf $completedTask.Mp4Path)"
            }
            elseif ([int]$completedTask.RetryCount -lt $RetryLimit) {
                $completedTask.RetryCount = [int]$completedTask.RetryCount + 1
                Write-Warning "Download failed, retrying: $(Split-Path -Leaf $completedTask.Mp4Path) (retry $($completedTask.RetryCount)/$RetryLimit)"
                $Tasks += $completedTask
            }
            else {
                Write-Warning "Download failed after $($RetryLimit + 1) attempt(s): $(Split-Path -Leaf $completedTask.Mp4Path)"
            }
        }
        else {
            if ((Test-Path -LiteralPath $completedTask.Mp4Path) -and (Get-Item -LiteralPath $completedTask.Mp4Path).Length -gt 0) {
                Write-Host "Finished MP4: $(Split-Path -Leaf $completedTask.Mp4Path)"
            }
            elseif ([int]$completedTask.RetryCount -lt $RetryLimit) {
                $completedTask.RetryCount = [int]$completedTask.RetryCount + 1
                Write-Warning "MP4 output missing, retrying: $(Split-Path -Leaf $completedTask.Mp4Path) (retry $($completedTask.RetryCount)/$RetryLimit)"
                $Tasks += $completedTask
            }
            else {
                Write-Warning "MP4 output missing after $($RetryLimit + 1) attempt(s): $(Split-Path -Leaf $completedTask.Mp4Path)"
            }
        }

        Remove-Job -Job $completedJob
        $running = @($running | Where-Object { $_.Job.Id -ne $completedJob.Id })
    }
}

$listHeader = "mhtml_file`tembed_html`tvideo_size"
Set-Content -LiteralPath $ListPath -Value $listHeader -Encoding UTF8
Sync-ListBackup -Path $ListPath
$epicDownloadTasks = @()
$youtubeDownloadTasks = @()
$listEntries = @()
$queuedMp4Paths = @{}
$mhtmlRoot = Join-Path $Root 'mhtml'

if (-not (Test-Path -LiteralPath $mhtmlRoot)) {
    Write-Host "MHTML folder not found: $mhtmlRoot"
    exit 0
}

$mhtmlFiles = Get-ChildItem -LiteralPath $mhtmlRoot -Filter '*.mhtml' -File -Recurse
if (-not $mhtmlFiles) {
    Write-Host "No .mhtml files found in $mhtmlRoot"
    exit 0
}

foreach ($mhtmlFile in $mhtmlFiles) {
    Write-Host ""
    Write-Host "Scanning MHTML: $($mhtmlFile.Name)"
    $mhtmlText = Get-Content -LiteralPath $mhtmlFile.FullName -Raw
    $embedUrls = @(Get-EmbedUrlsFromMhtml $mhtmlText)
    $youtubeUrls = @(Get-YoutubeEmbedUrlsFromMhtml $mhtmlText)
    $localMp4Urls = @(Get-LocalMp4UrlsFromMhtml $mhtmlText)
    $localVideoIds = @{}

    foreach ($localMp4Url in $localMp4Urls) {
        $localVideoId = Get-LocalMp4VideoIdFromUrl $localMp4Url
        if (-not $localVideoId) {
            continue
        }

        $localVideoIds[$localVideoId] = $true
        $mp4Path = Join-Path $Mp4Dir "$localVideoId.mp4"
        [void](Restore-Mp4FromOld -Mp4Path $mp4Path)

        if (-not (Test-Path -LiteralPath $mp4Path)) {
            Write-Warning "Local MP4 referenced but not found: $localVideoId.mp4"
        }

        $listEntries += [pscustomobject]@{
            MhtmlPath = $mhtmlFile.FullName
            EmbedUrl = $localMp4Url
            Mp4Path = $mp4Path
        }
    }

    if (-not $embedUrls -and -not $youtubeUrls -and -not $localMp4Urls) {
        Write-Host 'No Epic, YouTube, or local MP4 URLs found.'
        continue
    }

    foreach ($youtubeUrl in $youtubeUrls) {
        $youtubeId = Get-YoutubeVideoIdFromUrl $youtubeUrl
        if (-not $youtubeId) {
            continue
        }

        $mp4Path = Join-Path $Mp4Dir "$youtubeId.mp4"
        $htmlPath = Join-Path $HtmlDir "$youtubeId.html"
        [void](Restore-Mp4FromOld -Mp4Path $mp4Path)

        Write-Host ""
        Write-Host "YouTube: $youtubeId"
        Save-YoutubeEmbedHtml -MhtmlText $mhtmlText -VideoId $youtubeId -HtmlPath $htmlPath

        if ($localVideoIds.ContainsKey($youtubeId)) {
            Write-Host "Skipping online download: local MP4 URL found for $youtubeId"
            continue
        }

        if ($SkipYoutubeVideo) {
            Write-Host "Skipping YouTube video download: $youtubeId"
            continue
        }

        $mp4Key = $mp4Path.ToLowerInvariant()
        if (-not $queuedMp4Paths.ContainsKey($mp4Key)) {
            $queuedMp4Paths[$mp4Key] = $true
            $youtubeDownloadTasks += [pscustomobject]@{
                Kind = 'youtube'
                MpdPath = $null
                SourceUrl = $youtubeUrl
                Mp4Path = $mp4Path
            }
        }

        $listEntries += [pscustomobject]@{
            MhtmlPath = $mhtmlFile.FullName
            EmbedUrl = $youtubeUrl
            Mp4Path = $mp4Path
        }
    }

    if (-not $embedUrls) {
        Close-OpenEmbedTabs
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
        [void](Restore-Mp4FromOld -Mp4Path $mp4Path)

        Write-Host ""
        Write-Host "Video: $videoId"

        if ($localVideoIds.ContainsKey($videoId)) {
            Write-Host "Skipping online download: local MP4 URL found for $videoId"
            $listEntries += [pscustomobject]@{
                MhtmlPath = $mhtmlFile.FullName
                EmbedUrl = $embedUrl
                Mp4Path = $mp4Path
            }
            Close-OpenEmbedTabs
            continue
        }

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
                $epicDownloadTasks += [pscustomobject]@{
                    Kind = 'mpd'
                    MpdPath = $mpdPath
                    SourceUrl = $null
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

Invoke-ParallelDownloads -Tasks $epicDownloadTasks -MaxParallel $ParallelDownloads -RetryLimit $DownloadRetries
Invoke-ParallelDownloads -Tasks $youtubeDownloadTasks -MaxParallel $ParallelDownloads -RetryLimit $DownloadRetries

foreach ($entry in $listEntries) {
    Add-MpdListEntry -MhtmlPath $entry.MhtmlPath -EmbedUrl $entry.EmbedUrl -Mp4Path $entry.Mp4Path
}

Write-Host ""
Write-Host 'Done.'
pause
