param(
    [string]$Url = 'https://dev.epicgames.com/documentation/metahuman',
    [string]$ScopeUrl = 'https://dev.epicgames.com/documentation/metahuman',
    [string]$Root = $PSScriptRoot,
    [int]$BrowserPollSeconds = 2,
    [int]$ParallelDownloads = 10,
    [int]$MaxPages = 0
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = (Resolve-Path -LiteralPath $Root).Path
if ([string]::IsNullOrWhiteSpace($ScopeUrl)) {
    $ScopeUrl = $Url
}

$ParallelDownloads = [Math]::Max(1, $ParallelDownloads)
$BrowserPollSeconds = [Math]::Max(1, $BrowserPollSeconds)

$WebDir = Join-Path $Root 'web'
$PagesDir = Join-Path $WebDir 'pages'
$FilesDir = Join-Path $WebDir 'files'
$ListPath = Join-Path $Root 'web-list.txt'

New-Item -ItemType Directory -Force -Path $PagesDir, $FilesDir | Out-Null
Set-Content -LiteralPath $ListPath -Value "original_url`tfinal_url`tlocal_file" -Encoding UTF8

$script:BrowserPort = $null
$script:BrowserProfileDir = Join-Path $WebDir '.browser-profile'

function Get-BrowserPath {
    foreach ($command in @('msedge', 'chrome')) {
        $found = Get-Command $command -ErrorAction SilentlyContinue
        if ($found) {
            return $found.Source
        }
    }

    foreach ($path in @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )) {
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
    param([int]$Port)

    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -ErrorAction Stop | Out-Null
            return
        }
        catch {
            Start-Sleep -Milliseconds 500
        }
    }

    throw "Browser DevTools did not start on port $Port."
}

function Ensure-Browser {
    if ($script:BrowserPort) {
        return
    }

    $browserPath = Get-BrowserPath
    if (-not $browserPath) {
        throw 'Cannot find Microsoft Edge or Google Chrome.'
    }

    $script:BrowserPort = Get-FreeTcpPort
    New-Item -ItemType Directory -Force -Path $script:BrowserProfileDir | Out-Null

    $arguments = @(
        "--remote-debugging-port=$($script:BrowserPort)",
        "--user-data-dir=$($script:BrowserProfileDir)",
        '--no-first-run',
        '--new-window',
        'about:blank'
    )

    Start-Process -FilePath $browserPath -ArgumentList $arguments | Out-Null
    Wait-DevTools -Port $script:BrowserPort
}

function Open-DevToolsUrl {
    param([string]$OpenUrl)

    Ensure-Browser
    $escapedUrl = [System.Uri]::EscapeDataString($OpenUrl)
    $devToolsUrl = "http://127.0.0.1:$($script:BrowserPort)/json/new?$escapedUrl"

    try {
        return Invoke-RestMethod -Method Put -Uri $devToolsUrl -ErrorAction Stop
    }
    catch {
        return Invoke-RestMethod -Uri $devToolsUrl -ErrorAction Stop
    }
}

function Close-DevToolsPage {
    param([string]$TargetId)

    if ([string]::IsNullOrWhiteSpace($TargetId)) {
        return
    }

    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$($script:BrowserPort)/json/close/$TargetId" -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
    }
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
    [void]$Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

    do {
        $responseText = Receive-WebSocketText $Socket
        $response = $responseText | ConvertFrom-Json
    } while ($response.id -ne $Id)

    return $response
}

function Invoke-PageEval {
    param(
        $Page,
        [string]$Expression
    )

    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    try {
        [void]$socket.ConnectAsync([Uri]$Page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        $response = Invoke-CdpCommand -Socket $socket -Id 1 -Method 'Runtime.evaluate' -Params @{
            expression = $Expression
            returnByValue = $true
        }

        return [string]$response.result.result.value
    }
    finally {
        $socket.Dispose()
    }
}

function Test-ChallengeHtml {
    param([string]$Html)

    if ([string]::IsNullOrWhiteSpace($Html)) {
        return $true
    }

    return $Html -match '(?i)(403 Forbidden|Enable JavaScript and cookies to continue|cf_challenge|cf-challenge|Just a moment|security check to continue)'
}

function Get-PageFromBrowser {
    param([string]$PageUrl)

    Write-Host "Opening browser page: $PageUrl"
    $page = Open-DevToolsUrl $PageUrl
    $attempt = 0

    while ($true) {
        $attempt++
        Start-Sleep -Seconds $BrowserPollSeconds

        try {
            $json = Invoke-PageEval -Page $page -Expression 'JSON.stringify({href: location.href, readyState: document.readyState, title: document.title, html: document.documentElement.outerHTML})'
            $data = $json | ConvertFrom-Json
        }
        catch {
            Write-Warning "Cannot read browser page yet. $($_.Exception.Message)"
            continue
        }

        if (-not (Test-ChallengeHtml $data.html) -and $data.html -match '(?i)<body\b') {
            return [pscustomobject]@{
                OriginalUrl = $PageUrl
                FinalUrl = [string]$data.href
                Html = [string]$data.html
                TargetId = [string]$page.id
            }
        }

        Write-Host "Waiting for page/challenge... attempt $attempt, state=$($data.readyState), title=$($data.title)"
    }
}

function Get-NormalizedScope {
    param([string]$Value)

    return ([Uri]$Value).AbsoluteUri.TrimEnd('/')
}

$NormalizedScope = Get-NormalizedScope $ScopeUrl

function Test-UrlInScope {
    param([string]$CandidateUrl)

    try {
        $absolute = ([Uri]$CandidateUrl).AbsoluteUri.TrimEnd('/')
    }
    catch {
        return $false
    }

    return (
        $absolute.Equals($NormalizedScope, [System.StringComparison]::OrdinalIgnoreCase) -or
        $absolute.StartsWith("$NormalizedScope/", [System.StringComparison]::OrdinalIgnoreCase) -or
        $absolute.StartsWith("$NormalizedScope?", [System.StringComparison]::OrdinalIgnoreCase) -or
        $absolute.StartsWith("$NormalizedScope#", [System.StringComparison]::OrdinalIgnoreCase)
    )
}

function Test-IframeAllowed {
    param([string]$FrameUrl)

    try {
        $uri = [Uri]$FrameUrl
        return ($uri.Scheme -in @('http', 'https') -and $uri.Host.Equals('dev.epicgames.com', [System.StringComparison]::OrdinalIgnoreCase))
    }
    catch {
        return $false
    }
}

function Resolve-Url {
    param(
        [string]$BaseUrl,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $trimmed = [System.Net.WebUtility]::HtmlDecode($Value.Trim())
    if ($trimmed -match '^(#|javascript:|mailto:|tel:|data:|blob:|about:)') {
        return $null
    }

    try {
        return ([Uri]::new([Uri]$BaseUrl, $trimmed)).AbsoluteUri
    }
    catch {
        return $null
    }
}

function Test-LooksLikePageUrl {
    param([string]$CandidateUrl)

    try {
        $path = ([Uri]$CandidateUrl).AbsolutePath
    }
    catch {
        return $false
    }

    $extension = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($extension)) {
        return $true
    }

    return $extension -in @('.html', '.htm', '.php', '.aspx')
}

function Resolve-RedirectUrl {
    param([string]$CandidateUrl)

    try {
        $request = [System.Net.HttpWebRequest]::Create($CandidateUrl)
        $request.Method = 'HEAD'
        $request.AllowAutoRedirect = $true
        $request.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome Safari'
        $response = $request.GetResponse()
        try {
            return $response.ResponseUri.AbsoluteUri
        }
        finally {
            $response.Close()
        }
    }
    catch {
        return $CandidateUrl
    }
}

function Get-ShortHash {
    param([string]$Text)

    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha1.ComputeHash($bytes)
        return (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 10)
    }
    finally {
        $sha1.Dispose()
    }
}

function ConvertTo-SafeSegment {
    param([string]$Value)

    $decoded = [System.Uri]::UnescapeDataString($Value)
    foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) {
        $decoded = $decoded.Replace($char, '_')
    }

    if ([string]::IsNullOrWhiteSpace($decoded)) {
        return '_'
    }

    return $decoded
}

function Get-LocalPathForUrl {
    param(
        [string]$ItemUrl,
        [string]$Kind
    )

    $uri = [Uri]$ItemUrl
    $baseDir = if ($Kind -eq 'page') { $PagesDir } else { $FilesDir }
    $segments = New-Object System.Collections.Generic.List[string]
    $segments.Add((ConvertTo-SafeSegment $uri.Host))

    $path = $uri.AbsolutePath.Trim('/')
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = 'index.html'
    }

    $pathSegments = $path.Split('/') | Where-Object { $_ -ne '' }
    foreach ($segment in $pathSegments) {
        $segments.Add((ConvertTo-SafeSegment $segment))
    }

    $last = $segments[$segments.Count - 1]
    $extension = [System.IO.Path]::GetExtension($last)

    if ($Kind -eq 'page') {
        if ([string]::IsNullOrWhiteSpace($extension)) {
            $segments.Add('index.html')
        }
        elseif ($extension -notin @('.html', '.htm')) {
            $segments[$segments.Count - 1] = "$last.html"
        }
    }
    elseif ([string]::IsNullOrWhiteSpace($extension)) {
        $segments[$segments.Count - 1] = "$last.bin"
    }

    if (-not [string]::IsNullOrWhiteSpace($uri.Query)) {
        $lastIndex = $segments.Count - 1
        $name = [System.IO.Path]::GetFileNameWithoutExtension($segments[$lastIndex])
        $ext = [System.IO.Path]::GetExtension($segments[$lastIndex])
        $segments[$lastIndex] = "$name.$(Get-ShortHash $uri.Query)$ext"
    }

    $localPath = $baseDir
    foreach ($segment in $segments) {
        $localPath = Join-Path $localPath $segment
    }

    return $localPath
}

function Get-AttributeLinks {
    param(
        [string]$Html,
        [string]$BaseUrl
    )

    $items = New-Object System.Collections.Generic.List[object]

    foreach ($match in [regex]::Matches($Html, '<a\b[^>]*?\bhref\s*=\s*(?:"(?<url>[^"]*)"|''(?<url>[^'']*)''|(?<url>[^\s>]+))', 'IgnoreCase')) {
        $url = Resolve-Url -BaseUrl $BaseUrl -Value $match.Groups['url'].Value
        if ($url) {
            $items.Add([pscustomobject]@{ Type = 'page'; Url = $url; Original = $match.Groups['url'].Value })
        }
    }

    foreach ($match in [regex]::Matches($Html, '<iframe\b[^>]*?\bsrc\s*=\s*(?:"(?<url>[^"]*)"|''(?<url>[^'']*)''|(?<url>[^\s>]+))', 'IgnoreCase')) {
        $url = Resolve-Url -BaseUrl $BaseUrl -Value $match.Groups['url'].Value
        if ($url) {
            $items.Add([pscustomobject]@{ Type = 'iframe'; Url = $url; Original = $match.Groups['url'].Value })
        }
    }

    foreach ($match in [regex]::Matches($Html, '<(?:img|script|link|source|video|audio|track|embed|object)\b[^>]*?\b(?:src|href|poster|data)\s*=\s*(?:"(?<url>[^"]*)"|''(?<url>[^'']*)''|(?<url>[^\s>]+))', 'IgnoreCase')) {
        $url = Resolve-Url -BaseUrl $BaseUrl -Value $match.Groups['url'].Value
        if ($url) {
            $items.Add([pscustomobject]@{ Type = 'resource'; Url = $url; Original = $match.Groups['url'].Value })
        }
    }

    foreach ($match in [regex]::Matches($Html, '\b(?:srcset|imagesrcset)\s*=\s*(?:"(?<value>[^"]*)"|''(?<value>[^'']*)'')', 'IgnoreCase')) {
        $srcset = [System.Net.WebUtility]::HtmlDecode($match.Groups['value'].Value)
        foreach ($part in $srcset.Split(',')) {
            $candidate = ($part.Trim().Split(' ') | Select-Object -First 1)
            $url = Resolve-Url -BaseUrl $BaseUrl -Value $candidate
            if ($url) {
                $items.Add([pscustomobject]@{ Type = 'resource'; Url = $url; Original = $candidate })
            }
        }
    }

    foreach ($match in [regex]::Matches($Html, 'url\((?:&quot;|"|''|\\")?(?<url>[^"''\)\s\\]+)', 'IgnoreCase')) {
        $url = Resolve-Url -BaseUrl $BaseUrl -Value $match.Groups['url'].Value
        if ($url) {
            $items.Add([pscustomobject]@{ Type = 'resource'; Url = $url; Original = $match.Groups['url'].Value })
        }
    }

    return $items
}

function Update-HtmlRedirectLinks {
    param(
        [string]$Html,
        [hashtable]$RedirectMap
    )

    $updated = $Html
    foreach ($key in $RedirectMap.Keys) {
        $from = [regex]::Escape($key)
        $to = [System.Net.WebUtility]::HtmlEncode($RedirectMap[$key])
        $updated = [regex]::Replace($updated, "(href\s*=\s*[""'])$from([""'])", "`${1}$to`${2}", 'IgnoreCase')
    }

    return $updated
}

function Add-ResourceTask {
    param(
        [System.Collections.ArrayList]$Queue,
        [hashtable]$Seen,
        [string]$ResourceUrl
    )

    if ([string]::IsNullOrWhiteSpace($ResourceUrl)) {
        return
    }

    try {
        $uri = [Uri]$ResourceUrl
        if ($uri.Scheme -notin @('http', 'https')) {
            return
        }
    }
    catch {
        return
    }

    $key = $ResourceUrl.ToLowerInvariant()
    if ($Seen.ContainsKey($key)) {
        return
    }

    $Seen[$key] = $true
    [void]$Queue.Add([pscustomobject]@{
        Url = $ResourceUrl
        LocalPath = Get-LocalPathForUrl -ItemUrl $ResourceUrl -Kind 'resource'
    })
}

function Start-ResourceJob {
    param(
        [string]$ResourceUrl,
        [string]$LocalPath
    )

    Start-Job -ArgumentList $ResourceUrl, $LocalPath -ScriptBlock {
        param([string]$ResourceUrl, [string]$LocalPath)

        $result = [ordered]@{
            Url = $ResourceUrl
            LocalPath = $LocalPath
            Success = $false
            Error = ''
        }

        try {
            $parent = Split-Path -Parent $LocalPath
            New-Item -ItemType Directory -Force -Path $parent | Out-Null

            $headers = @{
                'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome Safari'
            }

            Invoke-WebRequest -Uri $ResourceUrl -UseBasicParsing -Headers $headers -OutFile $LocalPath -ErrorAction Stop
            $result.Success = $true
        }
        catch {
            $result.Error = $_.Exception.Message
        }

        [pscustomobject]$result
    }
}

function Process-ResourceQueue {
    param(
        [System.Collections.ArrayList]$Queue,
        [hashtable]$Seen
    )

    $running = @()

    while ($Queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($Queue.Count -gt 0 -and $running.Count -lt $ParallelDownloads) {
            $task = $Queue[0]
            $Queue.RemoveAt(0)

            if (Test-Path -LiteralPath $task.LocalPath) {
                continue
            }

            Write-Host "Downloading file: $($task.Url)"
            $job = Start-ResourceJob -ResourceUrl $task.Url -LocalPath $task.LocalPath
            $running += [pscustomobject]@{
                Job = $job
                Task = $task
            }
        }

        if ($running.Count -eq 0) {
            continue
        }

        $completedJob = Wait-Job -Job ($running.Job) -Any
        $resourceResult = Receive-Job -Job $completedJob
        Remove-Job -Job $completedJob
        $running = @($running | Where-Object { $_.Job.Id -ne $completedJob.Id })

        if (-not $resourceResult.Success) {
            Write-Warning "File download failed: $($resourceResult.Url) - $($resourceResult.Error)"
            continue
        }

        $extension = [System.IO.Path]::GetExtension($resourceResult.LocalPath).ToLowerInvariant()
        if ($extension -eq '.css') {
            try {
                $css = Get-Content -LiteralPath $resourceResult.LocalPath -Raw
                foreach ($match in [regex]::Matches($css, 'url\((?:&quot;|"|''|\\")?(?<url>[^"''\)\s\\]+)', 'IgnoreCase')) {
                    $url = Resolve-Url -BaseUrl $resourceResult.Url -Value $match.Groups['url'].Value
                    Add-ResourceTask -Queue $Queue -Seen $Seen -ResourceUrl $url
                }
            }
            catch {
                Write-Warning "Cannot parse CSS: $($resourceResult.LocalPath)"
            }
        }
    }
}

$pageQueue = New-Object System.Collections.ArrayList
$seenPages = @{}
$resourceQueue = New-Object System.Collections.ArrayList
$seenResources = @{}

[void]$pageQueue.Add([pscustomobject]@{
    Url = ([Uri]$Url).AbsoluteUri
    Kind = 'page'
    OriginalUrl = ([Uri]$Url).AbsoluteUri
})
$seenPages[(([Uri]$Url).AbsoluteUri.ToLowerInvariant())] = $true

$downloadedPages = 0

while ($pageQueue.Count -gt 0) {
    if ($MaxPages -gt 0 -and $downloadedPages -ge $MaxPages) {
        Write-Host "MaxPages reached: $MaxPages"
        break
    }

    $task = $pageQueue[0]
    $pageQueue.RemoveAt(0)

    $pageResult = $null
    try {
        $pageResult = Get-PageFromBrowser -PageUrl $task.Url
        $finalUrl = $pageResult.FinalUrl
        $html = $pageResult.Html
        $items = @(Get-AttributeLinks -Html $html -BaseUrl $finalUrl)
        $redirectMap = @{}

        foreach ($item in $items) {
            if ($item.Type -eq 'resource') {
                Add-ResourceTask -Queue $resourceQueue -Seen $seenResources -ResourceUrl $item.Url
                continue
            }

            if ($item.Type -eq 'iframe') {
                if (Test-IframeAllowed $item.Url) {
                    $iframeKey = "iframe:$($item.Url.ToLowerInvariant())"
                    if (-not $seenPages.ContainsKey($iframeKey)) {
                        $seenPages[$iframeKey] = $true
                        [void]$pageQueue.Add([pscustomobject]@{
                            Url = $item.Url
                            Kind = 'iframe'
                            OriginalUrl = $item.Url
                        })
                    }
                }
                continue
            }

            if (-not (Test-LooksLikePageUrl $item.Url)) {
                Add-ResourceTask -Queue $resourceQueue -Seen $seenResources -ResourceUrl $item.Url
                continue
            }

            $candidateUrl = $item.Url
            $resolvedUrl = $candidateUrl
            if (-not (Test-UrlInScope $candidateUrl)) {
                $resolvedUrl = Resolve-RedirectUrl $candidateUrl
            }

            if (Test-UrlInScope $resolvedUrl) {
                if (-not $resolvedUrl.Equals($candidateUrl, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $redirectMap[$item.Original] = $resolvedUrl
                }

                $pageKey = "page:$($resolvedUrl.ToLowerInvariant())"
                if (-not $seenPages.ContainsKey($pageKey)) {
                    $seenPages[$pageKey] = $true
                    [void]$pageQueue.Add([pscustomobject]@{
                        Url = $resolvedUrl
                        Kind = 'page'
                        OriginalUrl = $candidateUrl
                    })
                }
            }
        }

        if ($redirectMap.Count -gt 0) {
            $html = Update-HtmlRedirectLinks -Html $html -RedirectMap $redirectMap
        }

        $localPath = Get-LocalPathForUrl -ItemUrl $finalUrl -Kind 'page'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $localPath) | Out-Null
        [System.IO.File]::WriteAllText($localPath, $html, [System.Text.UTF8Encoding]::new($false))

        if ($task.Kind -eq 'page') {
            Add-Content -LiteralPath $ListPath -Value "$($task.OriginalUrl)`t$finalUrl`t$localPath" -Encoding UTF8
            $downloadedPages++
        }

        Write-Host "Saved $($task.Kind): $finalUrl"
        Process-ResourceQueue -Queue $resourceQueue -Seen $seenResources
    }
    catch {
        Write-Warning "Page failed: $($task.Url) - $($_.Exception.Message)"
    }
    finally {
        if ($pageResult) {
            Close-DevToolsPage -TargetId $pageResult.TargetId
        }
    }
}

Process-ResourceQueue -Queue $resourceQueue -Seen $seenResources

Write-Host ""
Write-Host "Done. Web pages listed in: $ListPath"
