param(
    [string]$Url = 'https://dev.epicgames.com/documentation/metahuman',
    [string]$ScopeUrl = '',
    [string]$Root = $PSScriptRoot,
    [int]$BrowserPollSeconds = 1,
    [int]$ParallelDownloads = 1,
    [int]$MaxPages = 0,
    [int]$MinPageWaitSeconds = 0,
    [int]$PageIdleSeconds = 2,
    [int]$PageLoadTimeoutSeconds = 120,
    [int]$ResourceLoadTimeoutSeconds = 30,
    [int]$ResourceRetrySeconds = 2
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = (Resolve-Path -LiteralPath $Root).Path
if ([string]::IsNullOrWhiteSpace($ScopeUrl)) {
    $ScopeUrl = $Url
}

$ParallelDownloads = [Math]::Max(1, $ParallelDownloads)
$BrowserPollSeconds = [Math]::Max(1, $BrowserPollSeconds)
$MinPageWaitSeconds = [Math]::Max(0, $MinPageWaitSeconds)
$PageIdleSeconds = [Math]::Max(0, $PageIdleSeconds)
$PageLoadTimeoutSeconds = [Math]::Max(1, $PageLoadTimeoutSeconds)
$ResourceLoadTimeoutSeconds = [Math]::Max(1, $ResourceLoadTimeoutSeconds)
$ResourceRetrySeconds = [Math]::Max(0, $ResourceRetrySeconds)

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

    foreach ($profileDir in @(
        $script:BrowserProfileDir,
        (Join-Path $WebDir ".browser-profile-$PID-$(Get-Date -Format 'yyyyMMddHHmmss')")
    )) {
        $script:BrowserPort = Get-FreeTcpPort
        New-Item -ItemType Directory -Force -Path $profileDir | Out-Null

        $arguments = @(
            "--remote-debugging-port=$($script:BrowserPort)",
            "--user-data-dir=$profileDir",
            '--disable-extensions',
            '--no-first-run',
            '--start-maximized',
            '--new-window',
            'about:blank'
        )

        Start-Process -FilePath $browserPath -ArgumentList $arguments -WindowStyle Maximized | Out-Null

        try {
            Wait-DevTools -Port $script:BrowserPort
            $script:BrowserProfileDir = $profileDir
            return
        }
        catch {
            Write-Warning $_.Exception.Message
            $script:BrowserPort = $null
        }
    }

    throw 'Browser DevTools did not start.'
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

function Get-BrowserSnapshotExpression {
    return @'
(() => {
  const items = [];
  const seenRoots = new Set();
  const add = (type, value) => {
    if (!value) return;
    try {
      const url = new URL(value, document.baseURI).href;
      if (/^(javascript|mailto|tel|data|blob|about):/i.test(url)) return;
      items.push({ type, url, original: value });
    } catch (_) {}
  };
  const walk = (root) => {
    if (!root || seenRoots.has(root)) return;
    seenRoots.add(root);
    root.querySelectorAll('a[href]').forEach(el => add('page', el.getAttribute('href')));
    root.querySelectorAll('iframe[src]').forEach(el => add('iframe', el.getAttribute('src')));
    root.querySelectorAll('img[src],script[src],link[href],source[src],video[src],audio[src],track[src],embed[src],object[data]').forEach(el => {
      add('resource', el.getAttribute('src') || el.getAttribute('href') || el.getAttribute('data'));
      add('resource', el.getAttribute('poster'));
    });
    root.querySelectorAll('[srcset],[imagesrcset]').forEach(el => {
      const srcset = el.getAttribute('srcset') || el.getAttribute('imagesrcset') || '';
      srcset.split(',').forEach(part => add('resource', part.trim().split(/\s+/)[0]));
    });
    root.querySelectorAll('*').forEach(el => {
      if (el.shadowRoot) walk(el.shadowRoot);
      const style = el.getAttribute('style') || '';
      for (const match of style.matchAll(/url\((?:"|'|&quot;)?([^"')\s]+)["']?\)/gi)) {
        add('resource', match[1]);
      }
    });
  };
  walk(document);
  const isVisible = (el) => {
    const style = getComputedStyle(el);
    if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) return false;
    const rect = el.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  };
  const loadingSelectors = [
    'spinner',
    '.spinner',
    '[aria-busy="true"]',
    '[class*="loading" i]',
    '[class*="skeleton" i]',
    '[class*="progress" i]',
    '[class*="shimmer" i]'
  ];
  const loadingElements = loadingSelectors
    .flatMap(selector => Array.from(document.querySelectorAll(selector)))
    .filter(isVisible);
  const html = document.documentElement.outerHTML;
  return JSON.stringify({
    href: location.href,
    readyState: document.readyState,
    title: document.title,
    html,
    htmlLength: html.length,
    loadingCount: loadingElements.length,
    isLoading: document.readyState !== 'complete' || loadingElements.length > 0,
    itemCount: items.length,
    items
  });
})()
'@
}

function Get-PageFromBrowser {
    param([string]$PageUrl)

    Write-Host "Opening browser page: $PageUrl"
    $page = Open-DevToolsUrl $PageUrl
    $attempt = 0
    $firstUsableAt = $null
    $stableSince = $null
    $lastSignature = ''
    $openedAt = Get-Date
    $snapshotExpression = Get-BrowserSnapshotExpression

    while ($true) {
        $attempt++
        Start-Sleep -Seconds $BrowserPollSeconds

        try {
            $json = Invoke-PageEval -Page $page -Expression $snapshotExpression
            $data = $json | ConvertFrom-Json
        }
        catch {
            Write-Warning "Cannot read browser page yet. $($_.Exception.Message)"
            continue
        }

        if (-not (Test-ChallengeHtml $data.html) -and $data.html -match '(?i)<body\b') {
            if (-not $firstUsableAt) {
                $firstUsableAt = Get-Date
            }

            $usableWaitedSeconds = ((Get-Date) - $firstUsableAt).TotalSeconds
            $totalWaitedSeconds = ((Get-Date) - $openedAt).TotalSeconds
            $signature = "$($data.href)|$($data.readyState)|$($data.isLoading)|$($data.loadingCount)|$($data.itemCount)|$($data.htmlLength)"

            if ($signature -ne $lastSignature) {
                $lastSignature = $signature
                $stableSince = Get-Date
            }

            $stableSeconds = ((Get-Date) - $stableSince).TotalSeconds
            $isReady = -not [System.Convert]::ToBoolean($data.isLoading)
            $minWaitDone = $usableWaitedSeconds -ge $MinPageWaitSeconds
            $idleDone = $stableSeconds -ge $PageIdleSeconds

            if ($isReady -and $minWaitDone -and $idleDone) {
                return [pscustomobject]@{
                    OriginalUrl = $PageUrl
                    FinalUrl = [string]$data.href
                    Html = [string]$data.html
                    Items = @($data.items)
                    TargetId = [string]$page.id
                }
            }

            if ($totalWaitedSeconds -ge $PageLoadTimeoutSeconds) {
                Write-Warning "Page load timeout reached. Saving current DOM: $($data.href)"
                return [pscustomobject]@{
                    OriginalUrl = $PageUrl
                    FinalUrl = [string]$data.href
                    Html = [string]$data.html
                    Items = @($data.items)
                    TargetId = [string]$page.id
                }
            }

            if (-not $isReady) {
                Write-Host "Waiting for loading to finish... attempt $attempt, state=$($data.readyState), loading=$($data.loadingCount), items=$($data.itemCount)"
                continue
            }

            Write-Host "Waiting for DOM to become idle... attempt $attempt, stable=$([int]$stableSeconds)s, items=$($data.itemCount)"
            continue
        }

        Write-Host "Waiting for page/challenge... attempt $attempt, state=$($data.readyState), title=$($data.title)"
    }
}

function Get-NormalizedScope {
    param([string]$Value)

    return ([Uri]$Value).AbsoluteUri.TrimEnd('/')
}

$NormalizedScope = Get-NormalizedScope $ScopeUrl

function Test-WebPageOutsideScope {
    param([string]$CandidateUrl)
    return ((Test-LooksLikePageUrl $CandidateUrl) -and (Test-HostUrlInScope $CandidateUrl))
}
function Test-HostUrlInScope {
    param([string]$CandidateUrl)

    try {
        $scope = [Uri]$NormalizedScope
        $url   = [Uri]$CandidateUrl
    }
    catch {
        return $false
    }

    # Scheme harus sama
    if ($scope.Scheme -ne $url.Scheme) {
        return $false
    }

    # Host harus sama
    if ($scope.Host -ne $url.Host) {
        return $false
    }

    # Port harus sama
    if ($scope.Port -ne $url.Port) {
        return $false
    }

    $scopePath = $scope.AbsolutePath.TrimEnd('/')
    $urlPath   = $url.AbsolutePath.TrimEnd('/')

    return (
        $urlPath -eq $scopePath -or
        $urlPath.StartsWith("$scopePath/")
    )
}
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

function Get-QueryMap {
    param([string]$Query)

    $map = @{}
    if ([string]::IsNullOrWhiteSpace($Query)) {
        return $map
    }

    foreach ($part in $Query.TrimStart('?').Split('&')) {
        if ([string]::IsNullOrWhiteSpace($part)) {
            continue
        }

        $pieces = $part.Split('=', 2)
        $key = [System.Uri]::UnescapeDataString($pieces[0])
        $value = if ($pieces.Count -gt 1) { [System.Uri]::UnescapeDataString($pieces[1]) } else { '' }
        $map[$key] = $value
    }

    return $map
}

function ConvertTo-QueryString {
    param(
        [hashtable]$QueryMap,
        [string[]]$ExcludeKeys = @(),
        [hashtable]$Override = $null
    )

    $excluded = @{}
    foreach ($key in $ExcludeKeys) {
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            $excluded[$key.ToLowerInvariant()] = $true
        }
    }

    $combined = @{}
    foreach ($key in $QueryMap.Keys) {
        if ($excluded.ContainsKey(([string]$key).ToLowerInvariant())) {
            continue
        }

        $combined[$key] = $QueryMap[$key]
    }

    if ($Override) {
        foreach ($key in $Override.Keys) {
            $combined[$key] = $Override[$key]
        }
    }

    $queryKeys = @($combined.Keys | Sort-Object)
    if ($queryKeys.Count -eq 0) {
        return ''
    }

    $parts = foreach ($key in $queryKeys) {
        "$([System.Uri]::EscapeDataString([string]$key))=$([System.Uri]::EscapeDataString([string]$combined[$key]))"
    }

    return '?' + ($parts -join '&')
}

function Test-QueryKeyExists {
    param(
        [hashtable]$QueryMap,
        [string]$Name
    )

    foreach ($key in $QueryMap.Keys) {
        if (([string]$key).ToLowerInvariant() -eq $Name.ToLowerInvariant()) {
            return $true
        }
    }

    return $false
}

function Get-PreferredPageUrl {
    param([string]$PageUrl)

    try {
        $uri = [Uri]$PageUrl
        $queryMap = Get-QueryMap $uri.Query
        if (-not (Test-QueryKeyExists -QueryMap $queryMap -Name 'lang')) {
            return $PageUrl
        }

        $builder = [UriBuilder]$uri
        $query = ConvertTo-QueryString -QueryMap $queryMap -ExcludeKeys @('lang') -Override @{ lang = 'en-US' }
        $builder.Query = $query.TrimStart('?')
        return $builder.Uri.AbsoluteUri
    }
    catch {
        return $PageUrl
    }
}

function Get-PageCanonicalKey {
    param([string]$PageUrl)

    $uri = [Uri]$PageUrl
    $queryMap = Get-QueryMap $uri.Query
    $query = ConvertTo-QueryString -QueryMap $queryMap -ExcludeKeys @('application_version', 'lang')

    return "$($uri.Scheme.ToLowerInvariant())://$($uri.Host.ToLowerInvariant())$($uri.AbsolutePath.TrimEnd('/'))$query"
}

function Get-ApplicationVersion {
    param([string]$PageUrl)

    try {
        $queryMap = Get-QueryMap ([Uri]$PageUrl).Query
        if ($queryMap.ContainsKey('application_version')) {
            return [version]([string]$queryMap['application_version'])
        }
    }
    catch {
    }

    return $null
}

function Compare-ApplicationVersion {
    param(
        [object]$Left,
        [object]$Right
    )

    if ($null -eq $Left -and $null -eq $Right) {
        return 0
    }

    if ($null -eq $Left) {
        return -1
    }

    if ($null -eq $Right) {
        return 1
    }

    return ([version]$Left).CompareTo([version]$Right)
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

function ConvertTo-RelativeWebPath {
    param(
        [string]$FromFile,
        [string]$ToFile
    )

    $fromDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($FromFile))
    $fromUri = [Uri]((Join-Path $fromDir '.') + [System.IO.Path]::DirectorySeparatorChar)
    $toUri = [Uri]([System.IO.Path]::GetFullPath($ToFile))
    return $fromUri.MakeRelativeUri($toUri).ToString()
}

function ConvertTo-RelativeRootPath {
    param([string]$Path)

    $rootUri = [Uri]((Join-Path $Root '.') + [System.IO.Path]::DirectorySeparatorChar)
    $pathUri = [Uri]([System.IO.Path]::GetFullPath($Path))
    return $rootUri.MakeRelativeUri($pathUri).ToString()
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

function Add-RewriteMapEntry {
    param(
        [hashtable]$Map,
        [string]$From,
        [string]$To
    )

    if ([string]::IsNullOrWhiteSpace($From) -or [string]::IsNullOrWhiteSpace($To)) {
        return
    }

    $decoded = [System.Net.WebUtility]::HtmlDecode($From)
    $Map[$From] = $To
    $Map[$decoded] = $To
    $Map[[System.Net.WebUtility]::HtmlEncode($decoded)] = $To
}

function Update-HtmlDownloadedLinks {
    param(
        [string]$Html,
        [hashtable]$RewriteMap
    )

    if (-not $RewriteMap -or $RewriteMap.Count -eq 0) {
        return $Html
    }

    $updated = $Html

    foreach ($key in ($RewriteMap.Keys | Sort-Object Length -Descending)) {
        $target = $RewriteMap[$key]
        $from = [regex]::Escape($key)
        $encodedTarget = [System.Net.WebUtility]::HtmlEncode($target)

        $updated = [regex]::Replace($updated, "((?:href|src|poster|data)\s*=\s*[""'])$from([""'])", "`${1}$encodedTarget`${2}", 'IgnoreCase')
        $updated = [regex]::Replace($updated, "(url\((?:&quot;|[""'])?)$from((?:&quot;|[""'])?\))", "`${1}$target`${2}", 'IgnoreCase')
    }

    $updated = [regex]::Replace($updated, '\b(?<attr>srcset|imagesrcset)\s*=\s*(?<quote>["''])(?<value>.*?)(\k<quote>)', {
        param($Match)

        $attr = $Match.Groups['attr'].Value
        $quote = $Match.Groups['quote'].Value
        $value = [System.Net.WebUtility]::HtmlDecode($Match.Groups['value'].Value)
        $parts = New-Object System.Collections.Generic.List[string]

        foreach ($part in $value.Split(',')) {
            $trimmed = $part.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) {
                continue
            }

            $tokens = $trimmed -split '\s+'
            $candidate = $tokens[0]
            if ($RewriteMap.ContainsKey($candidate)) {
                $tokens[0] = $RewriteMap[$candidate]
            }

            $parts.Add(($tokens -join ' '))
        }

        return "$attr=$quote$([System.Net.WebUtility]::HtmlEncode(($parts -join ', ')))$quote"
    }, 'IgnoreCase')

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

function Test-NotFoundError {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $false
    }

    return $Message -match '(?i)(404|not\s*found|ERR_HTTP_RESPONSE_CODE_FAILURE)'
}

function Save-BrowserResponseBody {
    param(
        [string]$ResourceUrl,
        [string]$LocalPath
    )

    Ensure-Browser
    $page = Open-DevToolsUrl 'about:blank'
    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $requestId = $null
    $statusCode = $null
    $commandId = 1

    try {
        [void]$socket.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

        [void](Invoke-CdpCommand -Socket $socket -Id $commandId -Method 'Network.enable')
        $commandId++
        [void](Invoke-CdpCommand -Socket $socket -Id $commandId -Method 'Page.enable')
        $commandId++
        try {
            [void](Invoke-CdpCommand -Socket $socket -Id $commandId -Method 'Page.setDownloadBehavior' -Params @{
                behavior = 'deny'
            })
        }
        catch {
        }
        $commandId++
        [void](Invoke-CdpCommand -Socket $socket -Id $commandId -Method 'Page.navigate' -Params @{ url = $ResourceUrl })
        $commandId++

        $deadline = (Get-Date).AddSeconds($ResourceLoadTimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            $messageText = Receive-WebSocketText $socket
            $message = $messageText | ConvertFrom-Json

            if ($message.method -eq 'Network.responseReceived') {
                $responseUrl = [string]$message.params.response.url
                if (-not $requestId -and $responseUrl -and (
                    $responseUrl.Equals($ResourceUrl, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $message.params.type -in @('Document', 'Image', 'Stylesheet', 'Script', 'Font', 'Media', 'Other', 'XHR', 'Fetch')
                )) {
                    $requestId = [string]$message.params.requestId
                    $statusCode = [int]$message.params.response.status
                }
            }

            if ($message.method -eq 'Network.loadingFinished' -and $requestId -and $message.params.requestId -eq $requestId) {
                break
            }
        }

        if (-not $requestId) {
            throw "No browser response captured for $ResourceUrl"
        }

        if ($statusCode -eq 404) {
            throw "404 Not Found"
        }

        $bodyResponse = Invoke-CdpCommand -Socket $socket -Id $commandId -Method 'Network.getResponseBody' -Params @{
            requestId = $requestId
        }

        $parent = Split-Path -Parent $LocalPath
        New-Item -ItemType Directory -Force -Path $parent | Out-Null

        if ($bodyResponse.result.base64Encoded) {
            $bytes = [Convert]::FromBase64String([string]$bodyResponse.result.body)
            [System.IO.File]::WriteAllBytes($LocalPath, $bytes)
        }
        else {
            [System.IO.File]::WriteAllText($LocalPath, [string]$bodyResponse.result.body, [System.Text.UTF8Encoding]::new($false))
        }

        return [pscustomobject]@{
            Url = $ResourceUrl
            LocalPath = $LocalPath
            Success = $true
            Error = ''
        }
    }
    catch {
        return [pscustomobject]@{
            Url = $ResourceUrl
            LocalPath = $LocalPath
            Success = $false
            Error = $_.Exception.Message
        }
    }
    finally {
        $socket.Dispose()
        Close-DevToolsPage -TargetId $page.id
    }
}

function Process-ResourceQueue {
    param(
        [System.Collections.ArrayList]$Queue,
        [hashtable]$Seen
    )

    while ($Queue.Count -gt 0) {
        $task = $Queue[0]
        $Queue.RemoveAt(0)

        if (Test-Path -LiteralPath $task.LocalPath) {
            continue
        }

        Write-Host "Opening file in browser: $($task.Url)"
        $resourceResult = Save-BrowserResponseBody -ResourceUrl $task.Url -LocalPath $task.LocalPath

        if (-not $resourceResult.Success) {
            if (Test-Path -LiteralPath $task.LocalPath) {
                Write-Host "File exists after warning, treating as downloaded: $($task.Url)"
                continue
            }

            if (Test-NotFoundError $resourceResult.Error) {
                Write-Warning "File not found, skipped: $($resourceResult.Url) - $($resourceResult.Error)"
                continue
            }

            Write-Warning "File download failed, retrying: $($resourceResult.Url) - $($resourceResult.Error)"
            if ($ResourceRetrySeconds -gt 0) {
                Start-Sleep -Seconds $ResourceRetrySeconds
            }

            [void]$Queue.Add($task)
            continue
        }

        $extension = [System.IO.Path]::GetExtension($resourceResult.LocalPath).ToLowerInvariant()
        if ($extension -eq '.css') {
            try {
                $css = Get-Content -LiteralPath $resourceResult.LocalPath -Raw
                $cssRewriteMap = @{}
                foreach ($match in [regex]::Matches($css, 'url\((?:&quot;|"|''|\\")?(?<url>[^"''\)\s\\]+)', 'IgnoreCase')) {
                    $url = Resolve-Url -BaseUrl $resourceResult.Url -Value $match.Groups['url'].Value
                    Add-ResourceTask -Queue $Queue -Seen $Seen -ResourceUrl $url
                    if ($url) {
                        $nestedLocalPath = Get-LocalPathForUrl -ItemUrl $url -Kind 'resource'
                        $relativeNestedPath = ConvertTo-RelativeWebPath -FromFile $resourceResult.LocalPath -ToFile $nestedLocalPath
                        Add-RewriteMapEntry -Map $cssRewriteMap -From $match.Groups['url'].Value -To $relativeNestedPath
                        Add-RewriteMapEntry -Map $cssRewriteMap -From $url -To $relativeNestedPath
                    }
                }

                if ($cssRewriteMap.Count -gt 0) {
                    $css = Update-HtmlDownloadedLinks -Html $css -RewriteMap $cssRewriteMap
                    [System.IO.File]::WriteAllText($resourceResult.LocalPath, $css, [System.Text.UTF8Encoding]::new($false))
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
$bestPageVersions = @{}
$downloadedPageCanonicals = @{}
$resourceQueue = New-Object System.Collections.ArrayList
$seenResources = @{}

function Get-PageSeenKey {
    param([string]$PageUrl)

    return "page:$(([Uri]$PageUrl).AbsoluteUri.TrimEnd('/').ToLowerInvariant())"
}

function Mark-PageSeen {
    param(
        [hashtable]$Seen,
        [string[]]$Urls
    )

    foreach ($pageUrl in $Urls) {
        if ([string]::IsNullOrWhiteSpace($pageUrl)) {
            continue
        }

        try {
            $Seen[(Get-PageSeenKey $pageUrl)] = $true
        }
        catch {
        }
    }
}

function Test-PageSeen {
    param(
        [hashtable]$Seen,
        [string]$PageUrl
    )

    try {
        return $Seen.ContainsKey((Get-PageSeenKey $PageUrl))
    }
    catch {
        return $false
    }
}

function Add-PageTask {
    param(
        [System.Collections.ArrayList]$Queue,
        [hashtable]$BestVersions,
        [hashtable]$DownloadedCanonicals,
        [string]$TaskUrl,
        [string]$Kind,
        [string]$OriginalUrl
    )

    $TaskUrl = Get-PreferredPageUrl $TaskUrl
    $canonicalKey = Get-PageCanonicalKey $TaskUrl
    $version = Get-ApplicationVersion $TaskUrl

    if ($DownloadedCanonicals.ContainsKey($canonicalKey)) {
        $downloadedVersion = $DownloadedCanonicals[$canonicalKey]
        if ((Compare-ApplicationVersion -Left $version -Right $downloadedVersion) -le 0) {
            return $false
        }
    }

    if ($BestVersions.ContainsKey($canonicalKey)) {
        $bestVersion = $BestVersions[$canonicalKey]
        if ((Compare-ApplicationVersion -Left $version -Right $bestVersion) -lt 0) {
            return $false
        }

        for ($index = $Queue.Count - 1; $index -ge 0; $index--) {
            try {
                if ((Get-PageCanonicalKey $Queue[$index].Url) -eq $canonicalKey) {
                    $Queue.RemoveAt($index)
                }
            }
            catch {
            }
        }
    }

    $BestVersions[$canonicalKey] = $version
    [void]$Queue.Add([pscustomobject]@{
        Url = $TaskUrl
        Kind = $Kind
        OriginalUrl = $OriginalUrl
        CanonicalKey = $canonicalKey
        ApplicationVersion = $version
    })

    return $true
}

$initialUrl = Get-PreferredPageUrl ([Uri]$Url).AbsoluteUri
[void](Add-PageTask -Queue $pageQueue -BestVersions $bestPageVersions -DownloadedCanonicals $downloadedPageCanonicals -TaskUrl $initialUrl -Kind 'page' -OriginalUrl ([Uri]$Url).AbsoluteUri)
Mark-PageSeen -Seen $seenPages -Urls @(([Uri]$Url).AbsoluteUri, $initialUrl)

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
        if (-not (Test-WebPageOutsideScope $task.Url)) {
            Write-Warning "Skipped page outside scope after redirect: $task.Url"
            continue
        }
        $pageResult = Get-PageFromBrowser -PageUrl $task.Url
        $finalUrl = $pageResult.FinalUrl
        Mark-PageSeen -Seen $seenPages -Urls @($task.Url, $task.OriginalUrl, $finalUrl)
        $html = $pageResult.Html
        $items = @($pageResult.Items) + @(Get-AttributeLinks -Html $html -BaseUrl $finalUrl)
        $localPath = Get-LocalPathForUrl -ItemUrl $finalUrl -Kind 'page'
        $rewriteMap = @{}

        foreach ($item in $items) {
            if ($item.Type -eq 'resource') {
                Add-ResourceTask -Queue $resourceQueue -Seen $seenResources -ResourceUrl $item.Url
                $resourceLocalPath = Get-LocalPathForUrl -ItemUrl $item.Url -Kind 'resource'
                $relativeResourcePath = ConvertTo-RelativeWebPath -FromFile $localPath -ToFile $resourceLocalPath
                Add-RewriteMapEntry -Map $rewriteMap -From $item.Original -To $relativeResourcePath
                Add-RewriteMapEntry -Map $rewriteMap -From $item.Url -To $relativeResourcePath
                continue
            }

            if ($item.Type -eq 'iframe') {
                if (Test-IframeAllowed $item.Url) {
                    $iframeUrl = Get-PreferredPageUrl $item.Url
                    $iframeLocalPath = Get-LocalPathForUrl -ItemUrl $iframeUrl -Kind 'page'
                    $relativeIframePath = ConvertTo-RelativeWebPath -FromFile $localPath -ToFile $iframeLocalPath
                    Add-RewriteMapEntry -Map $rewriteMap -From $item.Original -To $relativeIframePath
                    Add-RewriteMapEntry -Map $rewriteMap -From $item.Url -To $relativeIframePath
                    Add-RewriteMapEntry -Map $rewriteMap -From $iframeUrl -To $relativeIframePath

                    [void](Add-PageTask -Queue $pageQueue -BestVersions $bestPageVersions -DownloadedCanonicals $downloadedPageCanonicals -TaskUrl $iframeUrl -Kind 'iframe' -OriginalUrl $item.Url)
                    Mark-PageSeen -Seen $seenPages -Urls @($item.Url, $iframeUrl)
                }
                continue
            }

            if (-not (Test-LooksLikePageUrl $item.Url)) {
                Add-ResourceTask -Queue $resourceQueue -Seen $seenResources -ResourceUrl $item.Url
                $resourceLocalPath = Get-LocalPathForUrl -ItemUrl $item.Url -Kind 'resource'
                $relativeResourcePath = ConvertTo-RelativeWebPath -FromFile $localPath -ToFile $resourceLocalPath
                Add-RewriteMapEntry -Map $rewriteMap -From $item.Original -To $relativeResourcePath
                Add-RewriteMapEntry -Map $rewriteMap -From $item.Url -To $relativeResourcePath
                continue
            }

            $candidateUrl = $item.Url
            $resolvedUrl = $candidateUrl
            if (-not (Test-UrlInScope $candidateUrl)) {
                $resolvedUrl = Resolve-RedirectUrl $candidateUrl
            }

            $preferredResolvedUrl = Get-PreferredPageUrl $resolvedUrl

            if (Test-UrlInScope $preferredResolvedUrl) {
                $targetLocalPath = Get-LocalPathForUrl -ItemUrl $preferredResolvedUrl -Kind 'page'
                $relativePagePath = ConvertTo-RelativeWebPath -FromFile $localPath -ToFile $targetLocalPath
                Add-RewriteMapEntry -Map $rewriteMap -From $item.Original -To $relativePagePath
                Add-RewriteMapEntry -Map $rewriteMap -From $candidateUrl -To $relativePagePath
                Add-RewriteMapEntry -Map $rewriteMap -From $resolvedUrl -To $relativePagePath
                Add-RewriteMapEntry -Map $rewriteMap -From $preferredResolvedUrl -To $relativePagePath

                [void](Add-PageTask -Queue $pageQueue -BestVersions $bestPageVersions -DownloadedCanonicals $downloadedPageCanonicals -TaskUrl $preferredResolvedUrl -Kind 'page' -OriginalUrl $candidateUrl)
                Mark-PageSeen -Seen $seenPages -Urls @($candidateUrl, $resolvedUrl, $preferredResolvedUrl)
            }
        }

        $html = Update-HtmlDownloadedLinks -Html $html -RewriteMap $rewriteMap
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $localPath) | Out-Null
        [System.IO.File]::WriteAllText($localPath, $html, [System.Text.UTF8Encoding]::new($false))

        if ($task.Kind -eq 'page') {
            $relativeListPath = ConvertTo-RelativeRootPath $localPath
            Add-Content -LiteralPath $ListPath -Value "$($task.OriginalUrl)`t$finalUrl`t$relativeListPath" -Encoding UTF8
            $downloadedPages++
        }

        $downloadedPageCanonicals[(Get-PageCanonicalKey $finalUrl)] = Get-ApplicationVersion $finalUrl

        Write-Host "Saved $($task.Kind): $finalUrl"
        if ($pageResult) {
            Close-DevToolsPage -TargetId $pageResult.TargetId
            $pageResult = $null
        }

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
pause
