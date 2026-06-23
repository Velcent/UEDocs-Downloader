param(
    [string]$Url = 'https://dev.epicgames.com/documentation/unreal-engine/API',
    [string]$OutputRoot = (Join-Path $PSScriptRoot 'mhtml\API'),
    [int]$BrowserPollSeconds = 1,
    [int]$PageIdleSeconds = .1,
    [int]$PageLoadTimeoutSeconds = 3000,
    [int]$MaxLoadAttempts = 100000,
    [int]$ParallelPages = 6,
    [int]$MaxPages = 0,
    [switch]$Overwrite,
    [switch]$WorkerMode,
    [int]$WorkerBrowserPort = 0,
    [string]$WorkerPageUrl = '',
    [string]$WorkerSaveFolder = '',
    [int]$WorkerId = 0,
    [string]$WorkerIpcDir = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$BrowserPollSeconds = [Math]::Max(1, $BrowserPollSeconds)
$PageIdleSeconds = [Math]::Max(0, $PageIdleSeconds)
$PageLoadTimeoutSeconds = [Math]::Max(1, $PageLoadTimeoutSeconds)
$MaxLoadAttempts = [Math]::Max(1, $MaxLoadAttempts)
$ParallelPages = [Math]::Min(30, [Math]::Max(1, $ParallelPages))

$MinimumMhtmlBytes = 650KB
$MhtmlRoot = Join-Path $PSScriptRoot 'mhtml'
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$ListPath = Join-Path $MhtmlRoot 'cpp_api-list.tsv'
$ListBackupPath = Join-Path $MhtmlRoot 'cpp_api-list.bak'
$LinkPath = Join-Path $MhtmlRoot 'cpp_api-link.tsv'
$LinkBackupPath = Join-Path $MhtmlRoot 'cpp_api-link.bak'
$script:BrowserPort = if ($WorkerMode) { $WorkerBrowserPort } else { $null }
$script:BrowserProfileDir = Join-Path $MhtmlRoot '.edge-profile'
$script:CdpCommandId = 0
$script:MainDocumentStatus = $null
$script:MainDocumentStatusText = ''
$script:MainDocumentFailedText = ''
$script:MainDocumentRequestId = ''

function Update-ListBackup {
    if (-not (Test-Path -LiteralPath $ListPath)) {
        return
    }

    try {
        $tempPath = "$ListBackupPath.tmp"
        Copy-Item -LiteralPath $ListPath -Destination $tempPath -Force -ErrorAction Stop
        Move-Item -LiteralPath $tempPath -Destination $ListBackupPath -Force -ErrorAction Stop
    }
    catch {
        Write-Warning "Gagal membuat backup list: $ListBackupPath - $($_.Exception.Message)"
    }
}

if ($WorkerMode) {
    if ($WorkerBrowserPort -le 0) {
        throw 'WorkerBrowserPort wajib diisi untuk WorkerMode.'
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkerIpcDir)) {
        if ($WorkerId -le 0) {
            throw 'WorkerId wajib diisi untuk WorkerMode IPC.'
        }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($WorkerPageUrl)) {
            throw 'WorkerPageUrl wajib diisi untuk WorkerMode.'
        }
        if ([string]::IsNullOrWhiteSpace($WorkerSaveFolder)) {
            throw 'WorkerSaveFolder wajib diisi untuk WorkerMode.'
        }
    }
}
else {
    New-Item -ItemType Directory -Force -Path $MhtmlRoot, $OutputRoot | Out-Null
    if (-not (Test-Path -LiteralPath $ListPath) -or (Get-Item -LiteralPath $ListPath).Length -eq 0) {
        Set-Content -LiteralPath $ListPath -Value "url`tfile`ttitle`tchild_count`tparent_url" -Encoding UTF8
        Update-ListBackup
    }
    else {
        Write-Host "Resume dari list: $ListPath"
    }

    if (-not (Test-Path -LiteralPath $LinkPath) -or (Get-Item -LiteralPath $LinkPath).Length -eq 0) {
        Set-Content -LiteralPath $LinkPath -Value "url`tsave_folder`tchild_folder`tname`tparent_url" -Encoding UTF8
    }
    else {
        Write-Host "Resume dari link: $LinkPath"
    }
}

function Get-EdgePath {
    $command = Get-Command 'msedge' -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    foreach ($path in @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
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

    throw "Edge DevTools tidak aktif di port $Port."
}

function Ensure-Edge {
    if ($script:BrowserPort) {
        return
    }

    $edgePath = Get-EdgePath
    if (-not $edgePath) {
        throw 'Microsoft Edge tidak ditemukan.'
    }

    foreach ($profileDir in @(
        $script:BrowserProfileDir,
        (Join-Path $MhtmlRoot ".edge-profile-$PID-$(Get-Date -Format 'yyyyMMddHHmmss')")
    )) {
        $script:BrowserPort = Get-FreeTcpPort
        New-Item -ItemType Directory -Force -Path $profileDir | Out-Null

        $arguments = @(
            "--remote-debugging-port=$($script:BrowserPort)",
            "--user-data-dir=$profileDir",
            '--no-first-run',
            '--new-window',
            'about:blank'
        )

        Start-Process -FilePath $edgePath -ArgumentList $arguments | Out-Null

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

    throw 'Edge DevTools gagal dimulai.'
}

function Open-DevToolsUrl {
    param([string]$OpenUrl)

    Ensure-Edge
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
        [string]$Method,
        [hashtable]$Params = @{}
    )

    $script:CdpCommandId++
    $id = $script:CdpCommandId
    $message = @{
        id = $id
        method = $Method
        params = $Params
    } | ConvertTo-Json -Depth 30 -Compress

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($message)
    $segment = [ArraySegment[byte]]::new($bytes)
    [void]$Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

    do {
        $responseText = Receive-WebSocketText $Socket
        $response = $responseText | ConvertFrom-Json
        if (-not $response.id) {
            Update-NetworkStateFromEvent -Message $response
        }
    } while ($response.id -ne $id)

    if ($response.error) {
        throw "$Method gagal: $($response.error.message)"
    }

    return $response
}

function Reset-NetworkState {
    $script:MainDocumentStatus = $null
    $script:MainDocumentStatusText = ''
    $script:MainDocumentFailedText = ''
    $script:MainDocumentRequestId = ''
}

function Update-NetworkStateFromEvent {
    param($Message)

    if (-not $Message -or -not $Message.method) {
        return
    }

    if ($Message.method -eq 'Network.requestWillBeSent' -and $Message.params.type -eq 'Document') {
        $script:MainDocumentRequestId = [string]$Message.params.requestId
        return
    }

    if ($Message.method -eq 'Network.responseReceived' -and $Message.params.type -eq 'Document') {
        $script:MainDocumentRequestId = [string]$Message.params.requestId
        $script:MainDocumentStatus = [int]$Message.params.response.status
        $script:MainDocumentStatusText = [string]$Message.params.response.statusText
        return
    }

    if ($Message.method -eq 'Network.loadingFailed') {
        $requestId = [string]$Message.params.requestId
        $errorText = [string]$Message.params.errorText
        $isDocumentFailure = ([string]$Message.params.type) -eq 'Document'
        $isKnownMainDocument = $script:MainDocumentRequestId -and $requestId -eq $script:MainDocumentRequestId

        if ($isDocumentFailure -or $isKnownMainDocument) {
            if ($requestId) {
                $script:MainDocumentRequestId = $requestId
            }
            $script:MainDocumentFailedText = $errorText
        }
    }
}

function Update-NetworkStateFromNavigateResult {
    param($Response)

    if (-not $Response -or -not $Response.result) {
        return
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Response.result.errorText)) {
        $script:MainDocumentFailedText = [string]$Response.result.errorText
    }
}

function Assert-PageLoadOk {
    param($Data)

    if (-not [string]::IsNullOrWhiteSpace($script:MainDocumentFailedText)) {
        throw "Network error: $($script:MainDocumentFailedText)"
    }

    if ($null -ne $script:MainDocumentStatus -and $script:MainDocumentStatus -ge 400) {
        $statusText = if ($script:MainDocumentStatusText) { " $($script:MainDocumentStatusText)" } else { '' }
        throw "HTTP $($script:MainDocumentStatus)$statusText"
    }

    $title = [string]$Data.title
    $h1 = [string]$Data.h1
    $htmlLength = if ($Data.PSObject.Properties['htmlLength']) { [int]$Data.htmlLength } else { 0 }

    if ($h1 -eq 'One more step' -and $htmlLength -lt 102400) {
        throw "Halaman terlihat error challenge: h1='$h1', size=$htmlLength bytes"
    }

    if ("$title $h1" -match '(?i)\b(404|502|503|504|not found|bad gateway|service unavailable|gateway timeout|ERR_[A-Z_]+|DNS|internet|connection|refused|unreachable|timed out|can''t be reached)\b') {
        throw "Halaman terlihat error: title='$title', h1='$h1'"
    }
}

function Get-CPPSnapshotExpression {
    return @'
(() => {
  const normalize = (value) => (value || '').replace(/\s+/g, ' ').trim();
  const toUrl = (value) => {
    if (!value) return '';
    try {
      const url = new URL(value, document.baseURI);
      if (!/^https?:$/i.test(url.protocol)) return '';
      return url.href;
    } catch (_) {
      return '';
    }
  };
  const isVisible = (el) => {
    const style = getComputedStyle(el);
    if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) return false;
    const rect = el.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  };
  const normalizePageUrl = (value) => {
    const url = new URL(value, document.baseURI);
    url.hash = '';
    url.search = '';
    url.pathname = url.pathname.replace(/\/+$/, '');
    return url;
  };
  const pathSegments = (url) => url.pathname.replace(/\/+$/, '').split('/').filter(Boolean);
  const isOneLevelChild = (candidateUrl) => {
    try {
      const current = normalizePageUrl(location.href);
      const candidate = normalizePageUrl(candidateUrl);
      if (candidate.origin !== current.origin) return false;

      const currentSegments = pathSegments(current);
      const candidateSegments = pathSegments(candidate);
      if (candidateSegments.length !== currentSegments.length + 1) return false;

      return currentSegments.every((segment, index) => segment === candidateSegments[index]);
    } catch (_) {
      return false;
    }
  };
  const collectMarkdownChildren = () => {
    const items = [];
    const seen = new Set();

    document.querySelectorAll('.block-markdown a[href]').forEach((anchor) => {
      const href = toUrl(anchor.getAttribute('href'));
      if (!href || !isOneLevelChild(href)) return;

      const normalizedUrl = normalizePageUrl(href);

      const key = normalizedUrl.href;
      if (seen.has(key)) return;
      seen.add(key);

      const fallbackName = decodeURIComponent(normalizedUrl.pathname.split('/').filter(Boolean).pop() || key);
      const name = normalize(anchor.getAttribute('page-name') || anchor.textContent || fallbackName);
      items.push({ name, url: key });
    });

    return items;
  };
  const getParentUrl = () => {
    const nav = document.querySelector('h2#navigation');
    if (!nav) return '';
    let node = nav.nextElementSibling;
    while (node && !/^H[1-6]$/i.test(node.tagName)) {
      if (node.tagName?.toLowerCase() === 'p') {
        const links = Array.from(node.querySelectorAll('a[href]')).map(a => toUrl(a.getAttribute('href'))).filter(Boolean);
        if (links.length) return links[links.length - 1];
      }
      node = node.nextElementSibling;
    }
    return '';
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
  const loadingCount = loadingSelectors
    .flatMap(selector => Array.from(document.querySelectorAll(selector)))
    .filter(isVisible).length;
  const actions = collectMarkdownChildren();
  const h1 = document.querySelector('h1');
  const htmlLength = document.documentElement?.outerHTML?.length || 0;

  return JSON.stringify({
    href: location.href,
    readyState: document.readyState,
    title: document.title || '',
    h1: normalize(h1?.textContent || ''),
    hasH1: !!h1,
    actions,
    parentUrl: getParentUrl(),
    loadingCount,
    isLoading: document.readyState !== 'complete' || loadingCount > 0,
    htmlLength
  });
})()
'@
}

function Invoke-PageEval {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [string]$Expression
    )

    $response = Invoke-CdpCommand -Socket $Socket -Method 'Runtime.evaluate' -Params @{
        expression = $Expression
        returnByValue = $true
    }

    if ($response.result.exceptionDetails) {
        throw "Runtime evaluate gagal: $($response.result.exceptionDetails.text)"
    }

    return [string]$response.result.result.value
}

function ConvertTo-SafeSegment {
    param(
        [string]$Value,
        [int]$MaxLength = 90
    )

    $text = [System.Net.WebUtility]::HtmlDecode([string]$Value)
    try {
        $text = [System.Uri]::UnescapeDataString($text)
    }
    catch {
    }

    $text = ($text -replace '\s+', ' ').Trim()
    $invalidChars = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) {
        [void]$invalidChars.Add([int][char]$char)
    }

    $builder = [System.Text.StringBuilder]::new()
    foreach ($char in $text.ToCharArray()) {
        $code = [int][char]$char
        if ($invalidChars.Contains($code) -or $code -lt 32) {
            [void]$builder.Append("&#$code;")
        }
        else {
            [void]$builder.Append($char)
        }
    }

    $text = $builder.ToString().Trim(' ', '.')
    if ([string]::IsNullOrWhiteSpace($text)) {
        $text = '_'
    }

    if ($text -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
        $text = "_$text"
    }

    if ($text.Length -gt $MaxLength) {
        $sha1 = [System.Security.Cryptography.SHA1]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
            $hash = (($sha1.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 8)
            $prefixLength = [Math]::Max(1, $MaxLength - 9)
            $text = "$($text.Substring(0, $prefixLength).TrimEnd(' ', '.'))-$hash"
        }
        finally {
            $sha1.Dispose()
        }
    }

    return $text
}

function Get-CanonicalUrlKey {
    param([string]$PageUrl)

    try {
        $uri = [Uri]$PageUrl
        return "$($uri.Scheme.ToLowerInvariant())://$($uri.Host.ToLowerInvariant())$($uri.AbsolutePath.TrimEnd('/'))"
    }
    catch {
        return $PageUrl.TrimEnd('/').ToLowerInvariant()
    }
}

function ConvertTo-RelativeRootPath {
    param([string]$Path)

    $root = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($root.Length)
    }

    return $full
}

function Get-PageFilePath {
    param(
        [string]$Folder,
        [string]$Title,
        [string]$FileBaseName = ''
    )

    $baseName = if ([string]::IsNullOrWhiteSpace($FileBaseName)) {
        ConvertTo-SafeSegment -Value $Title -MaxLength 120
    }
    else {
        ConvertTo-SafeSegment -Value $FileBaseName -MaxLength 120
    }

    return (Join-Path $Folder "$baseName.mhtml")
}

function Get-TaskFileBaseName {
    param($Task)

    if (-not $Task -or [string]::IsNullOrWhiteSpace([string]$Task.SaveFolder) -or [string]::IsNullOrWhiteSpace([string]$Task.ChildFolder)) {
        return ''
    }

    $saveFolder = [System.IO.Path]::GetFullPath([string]$Task.SaveFolder)
    $childFolder = [System.IO.Path]::GetFullPath([string]$Task.ChildFolder)
    $childParent = [System.IO.Path]::GetDirectoryName($childFolder)
    if ($childParent -and $childParent.Equals($saveFolder, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [System.IO.Path]::GetFileName($childFolder)
    }

    return ''
}

function Get-NumberedDirectoryPath {
    param(
        [string]$Path,
        [int]$Index
    )

    if ($Index -le 0) {
        return $Path
    }

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    $name = [System.IO.Path]::GetFileName($Path)
    return (Join-Path $directory "${name}_${Index}")
}

function ConvertFrom-QuotedPrintableText {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }

    $withoutSoftBreaks = [regex]::Replace($Text, "=\r?\n", '')
    return [regex]::Replace($withoutSoftBreaks, '=([0-9A-Fa-f]{2})', {
        param($Match)
        [char][Convert]::ToInt32($Match.Groups[1].Value, 16)
    })
}

function Get-TagAttributeValue {
    param(
        [string]$TagText,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($TagText)) {
        return ''
    }

    $pattern = "(?i)\b$([regex]::Escape($Name))\s*=\s*(?:""(?<value>[^""]*)""|'(?<value>[^']*)'|(?<value>[^\s>]+))"
    $match = [regex]::Match($TagText, $pattern)
    if (-not $match.Success) {
        return ''
    }

    return [System.Net.WebUtility]::HtmlDecode($match.Groups['value'].Value)
}

function Resolve-PageUrl {
    param(
        [string]$BaseUrl,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    try {
        return ([Uri]::new([Uri]$BaseUrl, $Value)).AbsoluteUri
    }
    catch {
        return ''
    }
}

function Get-UrlPathSegments {
    param([Uri]$Url)

    return @($Url.AbsolutePath.Trim('/').Split('/') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-OneLevelChildUrl {
    param(
        [string]$BaseUrl,
        [string]$CandidateUrl
    )

    try {
        $base = [Uri](Get-NormalizedPageUrl -PageUrl $BaseUrl)
        $candidate = [Uri](Get-NormalizedPageUrl -PageUrl $CandidateUrl)
    }
    catch {
        return $false
    }

    if (-not $base.IsAbsoluteUri -or -not $candidate.IsAbsoluteUri) {
        return $false
    }

    if (-not $base.GetLeftPart([UriPartial]::Authority).Equals($candidate.GetLeftPart([UriPartial]::Authority), [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $baseSegments = @(Get-UrlPathSegments -Url $base)
    $candidateSegments = @(Get-UrlPathSegments -Url $candidate)
    if ($candidateSegments.Count -ne ($baseSegments.Count + 1)) {
        return $false
    }

    for ($index = 0; $index -lt $baseSegments.Count; $index++) {
        if (-not ([string]$baseSegments[$index]).Equals([string]$candidateSegments[$index], [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }

    return $true
}

function Get-NormalizedPageUrl {
    param([string]$PageUrl)

    try {
        $builder = [UriBuilder]([Uri]$PageUrl)
        $builder.Query = ''
        $builder.Fragment = ''
        $builder.Path = $builder.Path.TrimEnd('/')
        return $builder.Uri.AbsoluteUri
    }
    catch {
        return $PageUrl
    }
}

function Get-CPPDataFromMhtml {
    param(
        [string]$MhtmlPath,
        [string]$BaseUrl,
        [string]$FallbackTitle = '',
        [string]$FallbackParentUrl = ''
    )

    if (-not (Test-Path -LiteralPath $MhtmlPath)) {
        return $null
    }

    $raw = [System.IO.File]::ReadAllText($MhtmlPath)
    $decoded = [System.Net.WebUtility]::HtmlDecode((ConvertFrom-QuotedPrintableText $raw))
    $title = $FallbackTitle

    $h1Match = [regex]::Match($decoded, '<h1\b[^>]*>(?<value>.*?)</h1>', 'IgnoreCase,Singleline')
    if ($h1Match.Success) {
        $title = ([regex]::Replace($h1Match.Groups['value'].Value, '<[^>]+>', '') -replace '\s+', ' ').Trim()
    }

    $parentUrl = $FallbackParentUrl
    $navMatch = [regex]::Match($decoded, '<h2\b[^>]*\bid\s*=\s*(?:"navigation"|''navigation''|navigation)[^>]*>.*?</h2>(?<section>.*?)(?=<h[1-6]\b|$)', 'IgnoreCase,Singleline')
    if ($navMatch.Success) {
        $links = [regex]::Matches($navMatch.Groups['section'].Value, '<a\b(?<attrs>[^>]*)>', 'IgnoreCase')
        if ($links.Count -gt 0) {
            $lastHref = Get-TagAttributeValue -TagText $links[$links.Count - 1].Groups['attrs'].Value -Name 'href'
            $resolvedParent = Resolve-PageUrl -BaseUrl $BaseUrl -Value $lastHref
            if ($resolvedParent) {
                $parentUrl = $resolvedParent
            }
        }
    }

    $actions = New-Object System.Collections.Generic.List[object]
    $seenUrls = @{}
    $markdownPattern = '<(?<tag>[a-z0-9-]+)\b(?=[^>]*\bclass\s*=\s*(?:"[^"]*\bblock-markdown\b[^"]*"|''[^'']*\bblock-markdown\b[^'']*''|[^\s>]*\bblock-markdown\b[^\s>]*))[^>]*>(?<section>.*?)</\k<tag>>'
    foreach ($sectionMatch in [regex]::Matches($decoded, $markdownPattern, 'IgnoreCase,Singleline')) {
        foreach ($match in [regex]::Matches($sectionMatch.Groups['section'].Value, '<a\b(?<attrs>[^>]*)>(?<text>.*?)</a>', 'IgnoreCase,Singleline')) {
            $href = Resolve-PageUrl -BaseUrl $BaseUrl -Value (Get-TagAttributeValue -TagText $match.Groups['attrs'].Value -Name 'href')
            if (-not $href -or -not (Test-OneLevelChildUrl -BaseUrl $BaseUrl -CandidateUrl $href)) {
                continue
            }

            $href = Get-NormalizedPageUrl -PageUrl $href
            if ($seenUrls.ContainsKey($href)) {
                continue
            }
            $seenUrls[$href] = $true

            $name = ([regex]::Replace($match.Groups['text'].Value, '<[^>]+>', '') -replace '\s+', ' ').Trim()
            if ([string]::IsNullOrWhiteSpace($name)) {
                $name = ([Uri]$href).Segments[-1].Trim('/')
            }

            $actions.Add([pscustomobject]@{
                name = ($name -replace '\s+', ' ').Trim()
                url = $href
            })
        }
    }

    return [pscustomobject]@{
        OriginalUrl = $BaseUrl
        FinalUrl = $BaseUrl
        Title = $title
        FilePath = $MhtmlPath
        Saved = $false
        Actions = @($actions.ToArray())
        ParentUrl = $parentUrl
        Local = $true
    }
}

function Wait-CPPPageReady {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [string]$PageUrl,
        [int]$Attempt
    )

    $expression = Get-CPPSnapshotExpression
    $deadline = (Get-Date).AddSeconds($PageLoadTimeoutSeconds)
    $stableSince = $null
    $lastSignature = ''
    $lastData = $null

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $BrowserPollSeconds

        try {
            $json = Invoke-PageEval -Socket $Socket -Expression $expression
            $data = $json | ConvertFrom-Json
            $lastData = $data
        }
        catch {
            Write-Warning "Belum bisa membaca halaman, attempt ${Attempt}: $($_.Exception.Message)"
            continue
        }

        $signature = "$($data.href)|$($data.readyState)|$($data.isLoading)|$($data.loadingCount)|$($data.htmlLength)|$($data.h1)|$(@($data.actions).Count)"
        if ($signature -ne $lastSignature) {
            $lastSignature = $signature
            $stableSince = Get-Date
        }

        $stableSeconds = if ($stableSince) { ((Get-Date) - $stableSince).TotalSeconds } else { 0 }
        $documentComplete = ([string]$data.readyState) -eq 'complete'
        $isReady = -not [System.Convert]::ToBoolean($data.isLoading)
        $hasH1 = [System.Convert]::ToBoolean($data.hasH1) -and -not [string]::IsNullOrWhiteSpace([string]$data.h1)

        if (($isReady -or $documentComplete) -and $stableSeconds -ge $PageIdleSeconds) {
            if ($hasH1) {
                return $data
            }

            throw "h1 tidak ditemukan setelah halaman complete: $PageUrl"
        }

        # Write-Host "Menunggu load selesai: attempt=$Attempt ready=$($data.readyState) loading=$($data.loadingCount) stable=$([int]$stableSeconds)s url=$($data.href)"
    }

    if ($lastData -and -not [string]::IsNullOrWhiteSpace([string]$lastData.h1)) {
        Write-Warning "Timeout load, tetapi h1 sudah ada. Lanjut simpan DOM saat ini: $($lastData.href)"
        return $lastData
    }

    throw "Timeout load dan h1 belum tersedia: $PageUrl"
}

function New-CPPPageSession {
    Write-Host "Buka tab Edge"
    $page = Open-DevToolsUrl 'about:blank'
    $socket = [System.Net.WebSockets.ClientWebSocket]::new()

    try {
        [void]$socket.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

        [void](Invoke-CdpCommand -Socket $socket -Method 'Page.enable')
        [void](Invoke-CdpCommand -Socket $socket -Method 'Runtime.enable')
        [void](Invoke-CdpCommand -Socket $socket -Method 'Network.enable')

        return [pscustomobject]@{
            Page = $page
            Socket = $socket
        }
    }
    catch {
        $socket.Dispose()
        if ($page) {
            Close-DevToolsPage -TargetId $page.id
        }
        throw
    }
}

function Close-CPPPageSession {
    param($Session)

    if (-not $Session) {
        return
    }

    if ($Session.Socket) {
        $Session.Socket.Dispose()
    }
    if ($Session.Page) {
        Close-DevToolsPage -TargetId $Session.Page.id
    }
}

function Save-CPPPageAsMhtmlInSession {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [string]$PageUrl,
        [string]$Folder,
        [string]$FileBaseName = ''
    )

    Write-Host ""
    Write-Host "Buka Edge: $PageUrl"

    $data = $null
    $filePath = ''
    $saved = $false
    for ($attempt = 1; $attempt -le $MaxLoadAttempts; $attempt++) {
        Reset-NetworkState
        if ($attempt -eq 1) {
            $navigateResponse = Invoke-CdpCommand -Socket $Socket -Method 'Page.navigate' -Params @{ url = $PageUrl }
            Update-NetworkStateFromNavigateResult -Response $navigateResponse
        }
        else {
            Write-Warning "Navigasi ulang ke URL error karena metadata belum lengkap: $PageUrl"
            $navigateResponse = Invoke-CdpCommand -Socket $Socket -Method 'Page.navigate' -Params @{ url = $PageUrl }
            Update-NetworkStateFromNavigateResult -Response $navigateResponse
        }

        try {
            if (-not [string]::IsNullOrWhiteSpace($script:MainDocumentFailedText)) {
                throw "Network error: $($script:MainDocumentFailedText)"
            }

            $data = Wait-CPPPageReady -Socket $Socket -PageUrl $PageUrl -Attempt $attempt
            Assert-PageLoadOk -Data $data

            New-Item -ItemType Directory -Force -Path $Folder | Out-Null
            $filePath = Get-PageFilePath -Folder $Folder -Title $data.h1 -FileBaseName $FileBaseName

            $snapshot = Invoke-CdpCommand -Socket $Socket -Method 'Page.captureSnapshot' -Params @{ format = 'mhtml' }
            $snapshotData = [string]$snapshot.result.data
            $snapshotBytes = [System.Text.Encoding]::UTF8.GetByteCount($snapshotData)
            if ($snapshotBytes -lt $MinimumMhtmlBytes) {
                throw "MHTML terlalu kecil: $snapshotBytes bytes (< $MinimumMhtmlBytes bytes)"
            }

            [System.IO.File]::WriteAllText($filePath, $snapshotData, [System.Text.UTF8Encoding]::new($false))
            $saved = $true
            Write-Host "Simpan MHTML: $(ConvertTo-RelativeRootPath $filePath) ($snapshotBytes bytes)"
            break
        }
        catch {
            if ($attempt -ge $MaxLoadAttempts) {
                throw
            }
            Write-Warning $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        OriginalUrl = $PageUrl
        FinalUrl = [string]$data.href
        Title = [string]$data.h1
        FilePath = $filePath
        Saved = $saved
        Actions = @($data.actions)
        ParentUrl = [string]$data.parentUrl
    }
}

function Save-CPPPageAsMhtml {
    param(
        [string]$PageUrl,
        [string]$Folder,
        [string]$FileBaseName = ''
    )

    $session = $null
    try {
        $session = New-CPPPageSession
        return Save-CPPPageAsMhtmlInSession -Socket $session.Socket -PageUrl $PageUrl -Folder $Folder -FileBaseName $FileBaseName
    }
    finally {
        Close-CPPPageSession -Session $session
    }
}

function Get-WorkerFilePath {
    param(
        [string]$Directory,
        [int]$Id,
        [string]$Kind
    )

    return (Join-Path $Directory ("worker-{0:D3}.{1}" -f $Id, $Kind))
}

function New-WorkerSuccessResult {
    param(
        [int]$Id,
        [int]$TaskId,
        $Result
    )

    return [pscustomobject]@{
        WorkerResult = $true
        WorkerId = $Id
        TaskId = $TaskId
        Success = $true
        OriginalUrl = $Result.OriginalUrl
        FinalUrl = $Result.FinalUrl
        Title = $Result.Title
        FilePath = $Result.FilePath
        RelativeFile = (ConvertTo-RelativeRootPath $Result.FilePath)
        Saved = $Result.Saved
        Actions = @($Result.Actions)
        ParentUrl = $Result.ParentUrl
        Error = ''
    }
}

function New-WorkerErrorResult {
    param(
        [int]$Id,
        [int]$TaskId,
        [string]$PageUrl,
        [string]$ErrorMessage
    )

    return [pscustomobject]@{
        WorkerResult = $true
        WorkerId = $Id
        TaskId = $TaskId
        Success = $false
        OriginalUrl = $PageUrl
        FinalUrl = ''
        Title = ''
        FilePath = ''
        RelativeFile = ''
        Saved = $false
        Actions = @()
        ParentUrl = ''
        Error = $ErrorMessage
    }
}

function Invoke-PersistentPageWorker {
    param(
        [int]$Id,
        [string]$Directory
    )

    $workerDir = [System.IO.Path]::GetFullPath($Directory)
    $taskPath = Get-WorkerFilePath -Directory $workerDir -Id $Id -Kind 'task.json'
    $processingPath = Get-WorkerFilePath -Directory $workerDir -Id $Id -Kind 'processing.json'
    $resultPath = Get-WorkerFilePath -Directory $workerDir -Id $Id -Kind 'result.json'
    $stopPath = Get-WorkerFilePath -Directory $workerDir -Id $Id -Kind 'stop'

    $session = $null
    try {
        $session = New-CPPPageSession
        Write-Host "Worker #$Id siap menunggu task."

        while ($true) {
            if ((Test-Path -LiteralPath $stopPath) -and -not (Test-Path -LiteralPath $taskPath) -and -not (Test-Path -LiteralPath $processingPath)) {
                break
            }

            $currentTaskPath = $null
            if (Test-Path -LiteralPath $processingPath) {
                $currentTaskPath = $processingPath
            }
            elseif (Test-Path -LiteralPath $taskPath) {
                try {
                    Move-Item -LiteralPath $taskPath -Destination $processingPath -Force -ErrorAction Stop
                    $currentTaskPath = $processingPath
                }
                catch {
                    Start-Sleep -Milliseconds 250
                    continue
                }
            }

            if (-not $currentTaskPath) {
                Start-Sleep -Milliseconds 250
                continue
            }

            $task = $null
            $taskId = 0
            $pageUrl = ''
            try {
                $task = Get-Content -LiteralPath $currentTaskPath -Raw | ConvertFrom-Json
                $taskId = [int]$task.TaskId
                $pageUrl = [string]$task.Url

                if (-not $session -or $session.Socket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
                    Close-CPPPageSession -Session $session
                    $session = New-CPPPageSession
                }

                $workerResult = Save-CPPPageAsMhtmlInSession -Socket $session.Socket -PageUrl $pageUrl -Folder ([System.IO.Path]::GetFullPath([string]$task.SaveFolder)) -FileBaseName ([string]$task.FileBaseName)
                $result = New-WorkerSuccessResult -Id $Id -TaskId $taskId -Result $workerResult
            }
            catch {
                $result = New-WorkerErrorResult -Id $Id -TaskId $taskId -PageUrl $pageUrl -ErrorMessage $_.Exception.Message
            }

            $tempResultPath = "$resultPath.tmp"
            $result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $tempResultPath -Encoding UTF8
            Move-Item -LiteralPath $tempResultPath -Destination $resultPath -Force
            Remove-Item -LiteralPath $currentTaskPath -Force -ErrorAction SilentlyContinue
        }
    }
    finally {
        Close-CPPPageSession -Session $session
    }
}

if ($WorkerMode) {
    if (-not [string]::IsNullOrWhiteSpace($WorkerIpcDir)) {
        Invoke-PersistentPageWorker -Id $WorkerId -Directory $WorkerIpcDir
        return
    }

    try {
        $workerResult = Save-CPPPageAsMhtml -PageUrl $WorkerPageUrl -Folder ([System.IO.Path]::GetFullPath($WorkerSaveFolder))
        New-WorkerSuccessResult -Id $WorkerId -TaskId 0 -Result $workerResult
    }
    catch {
        New-WorkerErrorResult -Id $WorkerId -TaskId 0 -PageUrl $WorkerPageUrl -ErrorMessage $_.Exception.Message
    }
    return
}

function ConvertTo-LocalPathFromListValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    if ($Value -match '^file:/') {
        return ([Uri]$Value).LocalPath
    }

    if ([System.IO.Path]::IsPathRooted($Value)) {
        return $Value
    }

    return (Join-Path $PSScriptRoot $Value)
}

function Get-DownloadedPageMap {
    param([string]$Path)

    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $map
    }

    try {
        $rows = @(Import-Csv -LiteralPath $Path -Delimiter "`t")
    }
    catch {
        Write-Warning "Tidak bisa membaca list resume: $Path - $($_.Exception.Message)"
        return $map
    }

    foreach ($row in $rows) {
        if ([string]::IsNullOrWhiteSpace([string]$row.url)) {
            continue
        }

        try {
            $filePath = ConvertTo-LocalPathFromListValue $row.file
            $map[(Get-CanonicalUrlKey ([string]$row.url))] = [pscustomobject]@{
                Url = [string]$row.url
                FilePath = $filePath
                Title = [string]$row.title
                ChildCount = if ($row.child_count -match '^\d+$') { [int]$row.child_count } else { 0 }
                ParentUrl = [string]$row.parent_url
            }
        }
        catch {
        }
    }

    return $map
}

function Get-DownloadedFilePathMap {
    param([string]$Path)

    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $map
    }

    try {
        $rows = @(Import-Csv -LiteralPath $Path -Delimiter "`t")
    }
    catch {
        Write-Warning "Tidak bisa membaca file list untuk sync path: $Path - $($_.Exception.Message)"
        return $map
    }

    foreach ($row in $rows) {
        try {
            $filePath = ConvertTo-LocalPathFromListValue $row.file
            if ([string]::IsNullOrWhiteSpace($filePath)) {
                continue
            }

            $fullPath = [System.IO.Path]::GetFullPath($filePath)
            $map[$fullPath.ToLowerInvariant()] = $true
        }
        catch {
        }
    }

    return $map
}

function Get-MhtmlSourceUrl {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    try {
        $headerText = ((Get-Content -LiteralPath $Path -TotalCount 120) -join "`n")
        $match = [regex]::Match($headerText, '(?im)^(?:Snapshot-Content-Location|Content-Location):\s*(?<url>https?://[^\r\n]+(?:\r?\n[ \t][^\r\n]+)*)')
        if ($match.Success) {
            $url = [regex]::Replace($match.Groups['url'].Value, "\r?\n[ \t]+", '')
            return [System.Net.WebUtility]::HtmlDecode($url.Trim())
        }
    }
    catch {
    }

    return ''
}

function Get-LastDownloadedEntry {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $line = Get-Content -LiteralPath $Path -Tail 1
    if ([string]::IsNullOrWhiteSpace($line) -or $line -like "url`t*") {
        return $null
    }

    $parts = [string]$line -split "`t", 5
    if ($parts.Count -lt 5) {
        return $null
    }

    $filePath = ConvertTo-LocalPathFromListValue $parts[1]
    if ([string]::IsNullOrWhiteSpace($filePath) -or -not (Test-Path -LiteralPath $filePath)) {
        return $null
    }

    return [pscustomobject]@{
        Url = [string]$parts[0]
        FilePath = $filePath
        Title = [string]$parts[2]
        ChildCount = if ($parts[3] -match '^\d+$') { [int]$parts[3] } else { 0 }
        ParentUrl = [string]$parts[4]
    }
}

function ConvertTo-TsvValue {
    param([string]$Value)

    return ([string]$Value -replace "`t", ' ' -replace "\r?\n", ' ').Trim()
}

function Get-LinkTaskMap {
    param([string]$Path)

    $map = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $map
    }

    try {
        $rows = @(Import-Csv -LiteralPath $Path -Delimiter "`t")
    }
    catch {
        Write-Warning "Tidak bisa membaca link resume: $Path - $($_.Exception.Message)"
        return $map
    }

    foreach ($row in $rows) {
        if ([string]::IsNullOrWhiteSpace([string]$row.url)) {
            continue
        }

        try {
            $key = Get-CanonicalUrlKey ([string]$row.url)
            if ($map.Contains($key)) {
                continue
            }

            $saveFolder = ConvertTo-LocalPathFromListValue ([string]$row.save_folder)
            $childFolder = ConvertTo-LocalPathFromListValue ([string]$row.child_folder)
            if ([string]::IsNullOrWhiteSpace($saveFolder)) {
                $saveFolder = $OutputRoot
            }
            if ([string]::IsNullOrWhiteSpace($childFolder)) {
                $childFolder = $saveFolder
            }

            $map[$key] = [pscustomobject]@{
                Url = [string]$row.url
                SaveFolder = [System.IO.Path]::GetFullPath($saveFolder)
                ChildFolder = [System.IO.Path]::GetFullPath($childFolder)
                FileBaseName = (Get-TaskFileBaseName ([pscustomobject]@{
                    SaveFolder = [System.IO.Path]::GetFullPath($saveFolder)
                    ChildFolder = [System.IO.Path]::GetFullPath($childFolder)
                }))
                Name = [string]$row.name
                ParentUrl = [string]$row.parent_url
            }
        }
        catch {
        }
    }

    return $map
}

function Test-LinkChildFolderExists {
    param(
        [System.Collections.Specialized.OrderedDictionary]$LinkMap,
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    foreach ($entry in @($LinkMap.Values)) {
        if (-not $entry -or [string]::IsNullOrWhiteSpace([string]$entry.ChildFolder)) {
            continue
        }

        $entryPath = [System.IO.Path]::GetFullPath([string]$entry.ChildFolder)
        if ($entryPath.Equals($fullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-UniqueLinkChildFolder {
    param(
        [System.Collections.Specialized.OrderedDictionary]$LinkMap,
        [string]$Path
    )

    for ($index = 0; ; $index++) {
        $candidate = Get-NumberedDirectoryPath -Path $Path -Index $index
        if (-not (Test-LinkChildFolderExists -LinkMap $LinkMap -Path $candidate)) {
            return $candidate
        }
    }
}

function Update-LinkBackup {
    if (-not (Test-Path -LiteralPath $LinkPath)) {
        return
    }

    try {
        $tempPath = "$LinkBackupPath.tmp"
        Copy-Item -LiteralPath $LinkPath -Destination $tempPath -Force -ErrorAction Stop
        Move-Item -LiteralPath $tempPath -Destination $LinkBackupPath -Force -ErrorAction Stop
    }
    catch {
        Write-Warning "Gagal membuat backup link: $LinkBackupPath - $($_.Exception.Message)"
    }
}

function Add-LinkTask {
    param(
        [System.Collections.Specialized.OrderedDictionary]$LinkMap,
        $Task,
        [string]$Name = '',
        [string]$ParentUrl = ''
    )

    if (-not $Task -or [string]::IsNullOrWhiteSpace([string]$Task.Url)) {
        return $false
    }

    try {
        $key = Get-CanonicalUrlKey ([string]$Task.Url)
    }
    catch {
        return $false
    }

    if ($LinkMap.Contains($key)) {
        return $false
    }

    $saveFolder = [System.IO.Path]::GetFullPath([string]$Task.SaveFolder)
    $childFolder = [System.IO.Path]::GetFullPath([string]$Task.ChildFolder)
    $childFolder = Get-UniqueLinkChildFolder -LinkMap $LinkMap -Path $childFolder
    $Task.SaveFolder = $saveFolder
    $Task.ChildFolder = $childFolder
    $Task | Add-Member -NotePropertyName FileBaseName -NotePropertyValue (Get-TaskFileBaseName $Task) -Force
    $relativeSaveFolder = ConvertTo-RelativeRootPath $saveFolder
    $relativeChildFolder = ConvertTo-RelativeRootPath $childFolder

    Add-Content -LiteralPath $LinkPath -Value "$(ConvertTo-TsvValue $Task.Url)`t$(ConvertTo-TsvValue $relativeSaveFolder)`t$(ConvertTo-TsvValue $relativeChildFolder)`t$(ConvertTo-TsvValue $Name)`t$(ConvertTo-TsvValue $ParentUrl)" -Encoding UTF8
    Update-LinkBackup
    $LinkMap[$key] = [pscustomobject]@{
        Url = [string]$Task.Url
        SaveFolder = $saveFolder
        ChildFolder = $childFolder
        FileBaseName = [string]$Task.FileBaseName
        Name = $Name
        ParentUrl = $ParentUrl
    }

    return $true
}

function Add-PendingLinkTasks {
    param(
        [System.Collections.ArrayList]$Queue,
        [System.Collections.Specialized.OrderedDictionary]$LinkMap,
        [hashtable]$DownloadedMap
    )

    $tasks = @($LinkMap.Values)
    for ($index = $tasks.Count - 1; $index -ge 0; $index--) {
        $task = $tasks[$index]
        $key = Get-CanonicalUrlKey ([string]$task.Url)
        if ($DownloadedMap.ContainsKey($key)) {
            continue
        }

        [void]$Queue.Add([pscustomobject]@{
            Url = [string]$task.Url
            SaveFolder = [string]$task.SaveFolder
            ChildFolder = [string]$task.ChildFolder
            FileBaseName = [string]$task.FileBaseName
        })
    }
}

$stack = New-Object System.Collections.ArrayList
$visited = @{}
$downloadedMap = Get-DownloadedPageMap -Path $ListPath
$linkMap = Get-LinkTaskMap -Path $LinkPath
$downloaded = 0
$started = 0

if ($downloadedMap.Count -gt 0) {
    Write-Host "Index download terbaca: $($downloadedMap.Count) URL dari $ListPath"
}
if ($linkMap.Count -gt 0) {
    Write-Host "Index link terbaca: $($linkMap.Count) URL dari $LinkPath"
}

$rootTask = [pscustomobject]@{
    Url = ([Uri]$Url).AbsoluteUri
    SaveFolder = $OutputRoot
    ChildFolder = $OutputRoot
}
[void](Add-LinkTask -LinkMap $linkMap -Task $rootTask -Name 'root' -ParentUrl '')

function Add-ChildTasks {
    param(
        [System.Collections.ArrayList]$Queue,
        [hashtable]$Seen,
        [hashtable]$DownloadedMap,
        [System.Collections.Specialized.OrderedDictionary]$LinkMap,
        $Task,
        $Result
    )

    $actions = @($Result.Actions)
    $newLinkRows = New-Object System.Collections.ArrayList
    $newLinkEntries = New-Object System.Collections.ArrayList
    $pendingLinksByKey = @{}
    $pendingChildFolders = @{}
    $tasksToQueue = New-Object System.Collections.ArrayList

    for ($index = $actions.Count - 1; $index -ge 0; $index--) {
        $action = $actions[$index]
        if ([string]::IsNullOrWhiteSpace([string]$action.url)) {
            continue
        }

        try {
            $key = Get-CanonicalUrlKey ([string]$action.url)
        }
        catch {
            continue
        }

        if ($Seen.ContainsKey($key)) {
            continue
        }

        $childTask = $null
        if ($LinkMap.Contains($key)) {
            $existingTask = $LinkMap[$key]
            $childTask = [pscustomobject]@{
                Url = [string]$existingTask.Url
                SaveFolder = [string]$existingTask.SaveFolder
                ChildFolder = [string]$existingTask.ChildFolder
                FileBaseName = [string]$existingTask.FileBaseName
            }
        }
        elseif ($pendingLinksByKey.ContainsKey($key)) {
            $pendingEntry = $pendingLinksByKey[$key]
            $childTask = [pscustomobject]@{
                Url = [string]$pendingEntry.Task.Url
                SaveFolder = [string]$pendingEntry.Task.SaveFolder
                ChildFolder = [string]$pendingEntry.Task.ChildFolder
                FileBaseName = [string]$pendingEntry.Task.FileBaseName
            }
        }
        else {
            $childFolderName = ConvertTo-SafeSegment -Value $action.name -MaxLength 90
            $baseChildFolder = Join-Path $Task.ChildFolder $childFolderName
            for ($folderIndex = 0; ; $folderIndex++) {
                $childFolder = Get-NumberedDirectoryPath -Path $baseChildFolder -Index $folderIndex
                $childFolderKey = ([System.IO.Path]::GetFullPath($childFolder)).ToLowerInvariant()
                if (-not (Test-LinkChildFolderExists -LinkMap $LinkMap -Path $childFolder) -and -not $pendingChildFolders.ContainsKey($childFolderKey)) {
                    $pendingChildFolders[$childFolderKey] = $true
                    break
                }
            }

            $saveFolder = [System.IO.Path]::GetFullPath([string]$Task.ChildFolder)
            $childFolder = [System.IO.Path]::GetFullPath($childFolder)
            $childTask = [pscustomobject]@{
                Url = [string]$action.url
                SaveFolder = $saveFolder
                ChildFolder = $childFolder
            }
            $childTask | Add-Member -NotePropertyName FileBaseName -NotePropertyValue (Get-TaskFileBaseName $childTask) -Force

            $relativeSaveFolder = ConvertTo-RelativeRootPath $saveFolder
            $relativeChildFolder = ConvertTo-RelativeRootPath $childFolder
            $row = "$(ConvertTo-TsvValue $childTask.Url)`t$(ConvertTo-TsvValue $relativeSaveFolder)`t$(ConvertTo-TsvValue $relativeChildFolder)`t$(ConvertTo-TsvValue ([string]$action.name))`t$(ConvertTo-TsvValue ([string]$Result.OriginalUrl))"
            $entry = [pscustomobject]@{
                Key = $key
                Row = $row
                Task = $childTask
                MapValue = [pscustomobject]@{
                    Url = [string]$childTask.Url
                    SaveFolder = $saveFolder
                    ChildFolder = $childFolder
                    FileBaseName = [string]$childTask.FileBaseName
                    Name = [string]$action.name
                    ParentUrl = [string]$Result.OriginalUrl
                }
            }

            $pendingLinksByKey[$key] = $entry
            [void]$newLinkRows.Add($row)
            [void]$newLinkEntries.Add($entry)
        }

        if ($DownloadedMap.ContainsKey($key)) {
            continue
        }

        [void]$tasksToQueue.Add($childTask)
    }

    if ($newLinkRows.Count -gt 0) {
        Add-Content -LiteralPath $LinkPath -Value ([string[]]$newLinkRows.ToArray()) -Encoding UTF8
        foreach ($entry in @($newLinkEntries)) {
            $LinkMap[$entry.Key] = $entry.MapValue
        }
        Update-LinkBackup
    }

    foreach ($childTask in @($tasksToQueue)) {
        [void]$Queue.Add($childTask)
    }
}

function Add-DownloadedResultToList {
    param(
        $Result,
        [switch]$AllowExistingUrl
    )

    if (-not $Result -or [string]::IsNullOrWhiteSpace([string]$Result.OriginalUrl)) {
        return
    }

    $key = Get-CanonicalUrlKey ([string]$Result.OriginalUrl)
    if ($downloadedMap.ContainsKey($key) -and -not $AllowExistingUrl) {
        return
    }

    $relativeFile = if ($Result.RelativeFile) { $Result.RelativeFile } else { ConvertTo-RelativeRootPath $Result.FilePath }
    Add-Content -LiteralPath $ListPath -Value "$($Result.OriginalUrl)`t$relativeFile`t$($Result.Title)`t$(@($Result.Actions).Count)`t$($Result.ParentUrl)" -Encoding UTF8
    Update-ListBackup

    if (-not $downloadedMap.ContainsKey($key)) {
        $downloadedMap[$key] = [pscustomobject]@{
            Url = [string]$Result.OriginalUrl
            FilePath = [string]$Result.FilePath
            Title = [string]$Result.Title
            ChildCount = @($Result.Actions).Count
            ParentUrl = [string]$Result.ParentUrl
        }
    }
}

function Import-ExtraMhtmlFiles {
    param(
        [hashtable]$DownloadedMap,
        [System.Collections.Specialized.OrderedDictionary]$LinkMap
    )

    if (-not (Test-Path -LiteralPath $OutputRoot)) {
        return
    }

    $downloadedFiles = Get-DownloadedFilePathMap -Path $ListPath
    $extraFiles = @(Get-ChildItem -LiteralPath $OutputRoot -Recurse -File -Filter '*.mhtml' | Where-Object {
        -not $downloadedFiles.ContainsKey($_.FullName.ToLowerInvariant())
    })

    if ($extraFiles.Count -eq 0) {
        return
    }

    Write-Host "Scan file MHTML ekstra sebelum online: $($extraFiles.Count) file"
    foreach ($file in $extraFiles) {
        $sourceUrl = Get-MhtmlSourceUrl -Path $file.FullName
        if ([string]::IsNullOrWhiteSpace($sourceUrl)) {
            Write-Warning "Lewati file ekstra tanpa URL sumber: $(ConvertTo-RelativeRootPath $file.FullName)"
            continue
        }

        try {
            $key = Get-CanonicalUrlKey $sourceUrl
            $fallbackTitle = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            $result = Get-CPPDataFromMhtml -MhtmlPath $file.FullName -BaseUrl $sourceUrl -FallbackTitle $fallbackTitle
            if (-not $result) {
                Write-Warning "Tidak bisa scan file ekstra: $(ConvertTo-RelativeRootPath $file.FullName)"
                continue
            }

            $saveFolder = $file.DirectoryName
            $childFolder = Join-Path $saveFolder ([System.IO.Path]::GetFileNameWithoutExtension($file.Name))
            $task = [pscustomobject]@{
                Url = [string]$sourceUrl
                SaveFolder = $saveFolder
                ChildFolder = $childFolder
            }

            $addedLink = Add-LinkTask -LinkMap $LinkMap -Task $task -Name $result.Title -ParentUrl $result.ParentUrl
            if (-not $addedLink -and $LinkMap.Contains($key)) {
                $task.SaveFolder = [string]$LinkMap[$key].SaveFolder
                $task.ChildFolder = [string]$LinkMap[$key].ChildFolder
                $task | Add-Member -NotePropertyName FileBaseName -NotePropertyValue ([string]$LinkMap[$key].FileBaseName) -Force
            }

            Add-DownloadedResultToList -Result $result -AllowExistingUrl
            $temporaryQueue = New-Object System.Collections.ArrayList
            Add-ChildTasks -Queue $temporaryQueue -Seen @{} -DownloadedMap $DownloadedMap -LinkMap $LinkMap -Task $task -Result $result
            Write-Host "Adopsi MHTML ekstra: $(ConvertTo-RelativeRootPath $file.FullName)"
        }
        catch {
            Write-Warning "Gagal adopsi file ekstra: $(ConvertTo-RelativeRootPath $file.FullName) - $($_.Exception.Message)"
        }
    }
}

function Sync-LastDownloadedLinks {
    param(
        [hashtable]$DownloadedMap,
        [System.Collections.Specialized.OrderedDictionary]$LinkMap
    )

    $entry = Get-LastDownloadedEntry -Path $ListPath
    if (-not $entry) {
        return
    }

    $result = Get-CPPDataFromMhtml -MhtmlPath $entry.FilePath -BaseUrl $entry.Url -FallbackTitle $entry.Title -FallbackParentUrl $entry.ParentUrl
    if (-not $result) {
        Write-Warning "Tidak bisa scan link dari file terakhir: $($entry.FilePath)"
        return
    }

    $saveFolder = [System.IO.Path]::GetDirectoryName($entry.FilePath)
    $childFolder = Join-Path $saveFolder (ConvertTo-SafeSegment -Value $result.Title -MaxLength 90)
    try {
        $key = Get-CanonicalUrlKey $entry.Url
        if ($LinkMap.Contains($key)) {
            $saveFolder = [string]$LinkMap[$key].SaveFolder
            $childFolder = [string]$LinkMap[$key].ChildFolder
        }
    }
    catch {
    }

    $task = [pscustomobject]@{
        Url = [string]$entry.Url
        SaveFolder = $saveFolder
        ChildFolder = $childFolder
    }

    $beforeCount = $LinkMap.Count
    $temporaryQueue = New-Object System.Collections.ArrayList
    Add-ChildTasks -Queue $temporaryQueue -Seen @{} -DownloadedMap $DownloadedMap -LinkMap $LinkMap -Task $task -Result $result
    $addedCount = $LinkMap.Count - $beforeCount

    if ($addedCount -gt 0) {
        Write-Host "Sync link dari file terakhir: tambah $addedCount link dari $(ConvertTo-RelativeRootPath $entry.FilePath)"
    }
}

Sync-LastDownloadedLinks -DownloadedMap $downloadedMap -LinkMap $linkMap
Import-ExtraMhtmlFiles -DownloadedMap $downloadedMap -LinkMap $linkMap
Add-PendingLinkTasks -Queue $stack -LinkMap $linkMap -DownloadedMap $downloadedMap

function Write-ListEntry {
    param($Result)

    Add-DownloadedResultToList -Result $Result
}

function Get-NextTask {
    param(
        [System.Collections.ArrayList]$Queue,
        [hashtable]$Seen
    )

    while ($Queue.Count -gt 0) {
        $task = $Queue[$Queue.Count - 1]
        $Queue.RemoveAt($Queue.Count - 1)

        $key = Get-CanonicalUrlKey $task.Url
        if ($Seen.ContainsKey($key)) {
            continue
        }
        $Seen[$key] = $true
        return $task
    }

    return $null
}

function Test-CanStartMore {
    param([int]$StartedCount)

    return ($MaxPages -le 0 -or $StartedCount -lt $MaxPages)
}

function Add-FailedTaskBack {
    param(
        [System.Collections.ArrayList]$Queue,
        [hashtable]$Seen,
        $Task,
        [string]$ErrorMessage
    )

    $key = Get-CanonicalUrlKey $Task.Url
    if ($Seen.ContainsKey($key)) {
        $Seen.Remove($key)
    }

    $retryCount = 1
    if ($Task.PSObject.Properties['RetryCount']) {
        $retryCount = [int]$Task.RetryCount + 1
    }

    Write-Warning "Job gagal, masuk antrean ulang #${retryCount}: $($Task.Url) - $ErrorMessage"
    [void]$Queue.Add([pscustomobject]@{
        Url = [string]$Task.Url
        SaveFolder = [string]$Task.SaveFolder
        ChildFolder = [string]$Task.ChildFolder
        FileBaseName = [string]$Task.FileBaseName
        RetryCount = $retryCount
    })
}

function Start-PageWorkerJob {
    param(
        [int]$Id,
        [string]$IpcDir
    )

    Ensure-Edge
    Write-Host "Mulai worker #${Id}"

    $scriptPath = $PSCommandPath
    $initialization = {
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    }

    return Start-Job -InitializationScript $initialization -ScriptBlock {
        param(
            [string]$ScriptPath,
            [int]$BrowserPort,
            [int]$Id,
            [string]$IpcDir,
            [int]$BrowserPollSeconds,
            [int]$PageIdleSeconds,
            [int]$PageLoadTimeoutSeconds,
            [int]$MaxLoadAttempts,
            [bool]$OverwriteFlag
        )

        & $ScriptPath `
            -WorkerMode `
            -WorkerBrowserPort $BrowserPort `
            -WorkerId $Id `
            -WorkerIpcDir $IpcDir `
            -BrowserPollSeconds $BrowserPollSeconds `
            -PageIdleSeconds $PageIdleSeconds `
            -PageLoadTimeoutSeconds $PageLoadTimeoutSeconds `
            -MaxLoadAttempts $MaxLoadAttempts `
            -Overwrite:$OverwriteFlag
    } -ArgumentList @(
        $scriptPath,
        $script:BrowserPort,
        $Id,
        $IpcDir,
        $BrowserPollSeconds,
        $PageIdleSeconds,
        $PageLoadTimeoutSeconds,
        $MaxLoadAttempts,
        $Overwrite.IsPresent
    )
}

function Receive-PageWorkerOutput {
    param($Worker)

    if (-not $Worker -or -not $Worker.Job) {
        return
    }

    Receive-Job -Job $Worker.Job -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Host
}

function Send-TaskToWorker {
    param(
        $Worker,
        $Task,
        [int]$TaskId
    )

    $payload = [pscustomobject]@{
        TaskId = $TaskId
        Url = [string]$Task.Url
        SaveFolder = [string]$Task.SaveFolder
        ChildFolder = [string]$Task.ChildFolder
        FileBaseName = [string]$Task.FileBaseName
        RetryCount = if ($Task.PSObject.Properties['RetryCount']) { [int]$Task.RetryCount } else { 0 }
    }

    $tempPath = "$($Worker.TaskPath).tmp"
    $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $Worker.TaskPath -Force

    $Worker.Busy = $true
    $Worker.Task = $Task
    $Worker.TaskId = $TaskId
    Write-Host "Worker #$($Worker.Id) proses: $($Task.Url)"
}

function Receive-WorkerResult {
    param($Worker)

    if (-not (Test-Path -LiteralPath $Worker.ResultPath)) {
        return $null
    }

    $result = Get-Content -LiteralPath $Worker.ResultPath -Raw | ConvertFrom-Json
    Remove-Item -LiteralPath $Worker.ResultPath -Force -ErrorAction SilentlyContinue
    return $result
}

function Clear-WorkerPendingFiles {
    param($Worker)

    foreach ($path in @(
        $Worker.TaskPath,
        ($Worker.TaskPath -replace '\.task\.json$', '.processing.json'),
        $Worker.ResultPath,
        "$($Worker.TaskPath).tmp",
        "$($Worker.ResultPath).tmp"
    )) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-NextBrowserTask {
    param(
        [System.Collections.ArrayList]$Queue,
        [hashtable]$Seen,
        [hashtable]$DownloadedMap
    )

    while ($Queue.Count -gt 0 -and (Test-CanStartMore -StartedCount $started)) {
        $task = Get-NextTask -Queue $Queue -Seen $Seen
        if (-not $task) {
            return $null
        }

        $key = Get-CanonicalUrlKey ([string]$task.Url)
        if ($DownloadedMap.ContainsKey($key)) {
            continue
        }

        return $task
    }

    return $null
}

function Stop-PageWorkers {
    param(
        [System.Collections.ArrayList]$Workers,
        [string]$IpcDir
    )

    foreach ($worker in @($Workers)) {
        New-Item -ItemType File -Force -Path $worker.StopPath | Out-Null
    }

    foreach ($worker in @($Workers)) {
        if ($worker.Job) {
            [void](Wait-Job -Job $worker.Job -Timeout 10)
            Receive-PageWorkerOutput -Worker $worker
            Remove-Job -Job $worker.Job -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($IpcDir) -and (Test-Path -LiteralPath $IpcDir)) {
        Remove-Item -LiteralPath $IpcDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($ParallelPages -le 1) {
    while ($stack.Count -gt 0) {
        if (-not (Test-CanStartMore -StartedCount $started)) {
            Write-Host "MaxPages tercapai: $MaxPages"
            break
        }

        $task = Get-NextBrowserTask -Queue $stack -Seen $visited -DownloadedMap $downloadedMap
        if (-not $task) {
            break
        }

        $started++
        try {
            $result = Save-CPPPageAsMhtml -PageUrl $task.Url -Folder $task.SaveFolder -FileBaseName ([string]$task.FileBaseName)
            $downloaded++
            Write-ListEntry -Result $result
            Add-ChildTasks -Queue $stack -Seen $visited -DownloadedMap $downloadedMap -LinkMap $linkMap -Task $task -Result $result
        }
        catch {
            if ($started -gt 0) {
                $started--
            }
            Add-FailedTaskBack -Queue $stack -Seen $visited -Task $task -ErrorMessage $_.Exception.Message
        }
    }
}
else {
    Ensure-Edge
    Write-Host "ParallelPages aktif: $ParallelPages"

    $workerIpcDir = Join-Path $MhtmlRoot (".cpp-workers-$PID-{0}" -f (Get-Date -Format 'yyyyMMddHHmmss'))
    New-Item -ItemType Directory -Force -Path $workerIpcDir | Out-Null

    $workers = New-Object System.Collections.ArrayList
    for ($workerId = 1; $workerId -le $ParallelPages; $workerId++) {
        $job = Start-PageWorkerJob -Id $workerId -IpcDir $workerIpcDir
        [void]$workers.Add([pscustomobject]@{
            Id = $workerId
            Job = $job
            Busy = $false
            Task = $null
            TaskId = 0
            TaskPath = (Get-WorkerFilePath -Directory $workerIpcDir -Id $workerId -Kind 'task.json')
            ResultPath = (Get-WorkerFilePath -Directory $workerIpcDir -Id $workerId -Kind 'result.json')
            StopPath = (Get-WorkerFilePath -Directory $workerIpcDir -Id $workerId -Kind 'stop')
        })
    }

    $nextTaskId = 0
    try {
        while ($stack.Count -gt 0 -or @($workers | Where-Object { $_.Busy }).Count -gt 0) {
            $madeProgress = $false

            foreach ($worker in @($workers)) {
                Receive-PageWorkerOutput -Worker $worker

                $result = Receive-WorkerResult -Worker $worker
                if ($result) {
                    if ($result.Success) {
                        $downloaded++
                        Write-ListEntry -Result $result
                        Add-ChildTasks -Queue $stack -Seen $visited -DownloadedMap $downloadedMap -LinkMap $linkMap -Task $worker.Task -Result $result

                        $status = if ($result.Saved) { 'Simpan' } else { 'Lewati existing' }
                        Write-Host "${status}: $($result.RelativeFile)"
                    }
                    else {
                        if ($started -gt 0) {
                            $started--
                        }
                        Add-FailedTaskBack -Queue $stack -Seen $visited -Task $worker.Task -ErrorMessage $result.Error
                    }

                    $worker.Busy = $false
                    $worker.Task = $null
                    $worker.TaskId = 0
                    $madeProgress = $true
                }
                elseif ($worker.Busy -and $worker.Job.State -ne 'Running') {
                    if ($started -gt 0) {
                        $started--
                    }
                    Add-FailedTaskBack -Queue $stack -Seen $visited -Task $worker.Task -ErrorMessage "worker #$($worker.Id) berhenti sebelum mengembalikan hasil"

                    Clear-WorkerPendingFiles -Worker $worker
                    Remove-Job -Job $worker.Job -Force -ErrorAction SilentlyContinue
                    $worker.Job = Start-PageWorkerJob -Id $worker.Id -IpcDir $workerIpcDir
                    $worker.Busy = $false
                    $worker.Task = $null
                    $worker.TaskId = 0
                    $madeProgress = $true
                }
                elseif (-not $worker.Busy -and $worker.Job.State -ne 'Running') {
                    Clear-WorkerPendingFiles -Worker $worker
                    Remove-Job -Job $worker.Job -Force -ErrorAction SilentlyContinue
                    $worker.Job = Start-PageWorkerJob -Id $worker.Id -IpcDir $workerIpcDir
                    $madeProgress = $true
                }
            }

            foreach ($worker in @($workers | Where-Object { -not $_.Busy })) {
                if (-not (Test-CanStartMore -StartedCount $started)) {
                    break
                }

                $task = Get-NextBrowserTask -Queue $stack -Seen $visited -DownloadedMap $downloadedMap
                if (-not $task) {
                    break
                }

                $nextTaskId++
                Send-TaskToWorker -Worker $worker -Task $task -TaskId $nextTaskId
                $started++
                $madeProgress = $true
            }

            if (@($workers | Where-Object { $_.Busy }).Count -eq 0) {
                if (-not (Test-CanStartMore -StartedCount $started) -and $MaxPages -gt 0) {
                    Write-Host "MaxPages tercapai: $MaxPages"
                    break
                }

                if ($stack.Count -eq 0) {
                    break
                }
            }

            if (-not $madeProgress) {
                Start-Sleep -Milliseconds 250
            }
        }
    }
    finally {
        Stop-PageWorkers -Workers $workers -IpcDir $workerIpcDir
    }
}

Write-Host ""
Write-Host "Selesai. Total halaman tersimpan/diproses: $downloaded"
Write-Host "Daftar hasil: $ListPath"
pause

