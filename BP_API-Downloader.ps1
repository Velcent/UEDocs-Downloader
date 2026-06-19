param(
    [string]$Url = 'https://dev.epicgames.com/documentation/unreal-engine/BlueprintAPI',
    [string]$OutputRoot = (Join-Path $PSScriptRoot 'mhtml\BlueprintAPI'),
    [int]$BrowserPollSeconds = 1,
    [int]$PageIdleSeconds = .1,
    [int]$PageLoadTimeoutSeconds = 3000,
    [int]$MaxLoadAttempts = 100,
    [int]$ParallelPages = 30,
    [int]$MaxPages = 0,
    [switch]$Overwrite,
    [switch]$WorkerMode,
    [int]$WorkerBrowserPort = 0,
    [string]$WorkerPageUrl = '',
    [string]$WorkerSaveFolder = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$BrowserPollSeconds = [Math]::Max(1, $BrowserPollSeconds)
$PageIdleSeconds = [Math]::Max(0, $PageIdleSeconds)
$PageLoadTimeoutSeconds = [Math]::Max(1, $PageLoadTimeoutSeconds)
$MaxLoadAttempts = [Math]::Max(1, $MaxLoadAttempts)
$ParallelPages = [Math]::Min(30, [Math]::Max(1, $ParallelPages))

$MhtmlRoot = Join-Path $PSScriptRoot 'mhtml'
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$ListPath = Join-Path $MhtmlRoot 'bp_api-list.tsv'
$script:BrowserPort = if ($WorkerMode) { $WorkerBrowserPort } else { $null }
$script:BrowserProfileDir = Join-Path $MhtmlRoot '.edge-profile'
$script:CdpCommandId = 0
$script:MainDocumentStatus = $null
$script:MainDocumentStatusText = ''
$script:MainDocumentFailedText = ''
$script:MainDocumentRequestId = ''

if ($WorkerMode) {
    if ($WorkerBrowserPort -le 0) {
        throw 'WorkerBrowserPort wajib diisi untuk WorkerMode.'
    }
    if ([string]::IsNullOrWhiteSpace($WorkerPageUrl)) {
        throw 'WorkerPageUrl wajib diisi untuk WorkerMode.'
    }
    if ([string]::IsNullOrWhiteSpace($WorkerSaveFolder)) {
        throw 'WorkerSaveFolder wajib diisi untuk WorkerMode.'
    }
}
else {
    New-Item -ItemType Directory -Force -Path $MhtmlRoot, $OutputRoot | Out-Null
    if (-not (Test-Path -LiteralPath $ListPath) -or (Get-Item -LiteralPath $ListPath).Length -eq 0) {
        Set-Content -LiteralPath $ListPath -Value "url`tfinal_url`tfile`ttitle`tchild_count`tparent_url" -Encoding UTF8
    }
    else {
        Write-Host "Resume dari list: $ListPath"
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

    if ($Message.method -eq 'Network.responseReceived' -and $Message.params.type -eq 'Document') {
        $script:MainDocumentRequestId = [string]$Message.params.requestId
        $script:MainDocumentStatus = [int]$Message.params.response.status
        $script:MainDocumentStatusText = [string]$Message.params.response.statusText
        return
    }

    if ($Message.method -eq 'Network.loadingFailed' -and $script:MainDocumentRequestId -and ([string]$Message.params.requestId) -eq $script:MainDocumentRequestId) {
        $script:MainDocumentFailedText = [string]$Message.params.errorText
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
    if ("$title $h1" -match '(?i)\b(404|502|503|504|not found|bad gateway|service unavailable|gateway timeout)\b') {
        throw "Halaman terlihat error: title='$title', h1='$h1'"
    }
}

function Get-BlueprintSnapshotExpression {
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
  const collectAfterHeader = (header, selector) => {
    const items = [];
    const seen = new Set();
    const add = (el) => {
      if (!el || seen.has(el)) return;
      seen.add(el);
      const anchor = el.matches('a[href]') ? el : el.querySelector('a[href]');
      const href = toUrl(el.getAttribute('href') || anchor?.getAttribute('href'));
      if (!href) return;
      const name = normalize(el.getAttribute('page-name') || anchor?.textContent || el.textContent || href);
      items.push({ name, url: href });
    };

    if (!header) return items;
    let node = header.nextElementSibling;
    while (node) {
      if (/^H[1-6]$/i.test(node.tagName)) break;
      if (node.matches?.(selector)) add(node);
      node.querySelectorAll?.(selector).forEach(add);
      node = node.nextElementSibling;
    }
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
  const actionsHeader = document.querySelector('h2#actionsandcategories');
  const actions = collectAfterHeader(actionsHeader, 'block-dir-item-md');
  const h1 = document.querySelector('h1');
  const htmlLength = document.documentElement?.outerHTML?.length || 0;

  return JSON.stringify({
    href: location.href,
    readyState: document.readyState,
    title: document.title || '',
    h1: normalize(h1?.textContent || ''),
    hasH1: !!h1,
    hasActionsHeader: !!actionsHeader,
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
    foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) {
        $text = $text.Replace($char, '_')
    }

    $text = ($text -replace '[\x00-\x1f]', '_').Trim(' ', '.')
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
        [string]$Title
    )

    $baseName = ConvertTo-SafeSegment -Value $Title -MaxLength 120
    return (Join-Path $Folder "$baseName.mhtml")
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

function Get-BlueprintDataFromMhtml {
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
    $actionsMatch = [regex]::Match($decoded, '<h2\b[^>]*\bid\s*=\s*(?:"actionsandcategories"|''actionsandcategories''|actionsandcategories)[^>]*>.*?</h2>(?<section>.*?)(?=<h[1-6]\b|$)', 'IgnoreCase,Singleline')
    if ($actionsMatch.Success) {
        foreach ($match in [regex]::Matches($actionsMatch.Groups['section'].Value, '<block-dir-item-md\b(?<attrs>[^>]*)>', 'IgnoreCase')) {
            $attrs = $match.Groups['attrs'].Value
            $href = Resolve-PageUrl -BaseUrl $BaseUrl -Value (Get-TagAttributeValue -TagText $attrs -Name 'href')
            if (-not $href) {
                continue
            }

            $name = Get-TagAttributeValue -TagText $attrs -Name 'page-name'
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

function Wait-BlueprintPageReady {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [string]$PageUrl,
        [int]$Attempt
    )

    $expression = Get-BlueprintSnapshotExpression
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
        $isReady = -not [System.Convert]::ToBoolean($data.isLoading)
        $hasH1 = [System.Convert]::ToBoolean($data.hasH1) -and -not [string]::IsNullOrWhiteSpace([string]$data.h1)

        if ($isReady -and $stableSeconds -ge $PageIdleSeconds) {
            if ($hasH1) {
                return $data
            }

            throw "h1 tidak ditemukan setelah halaman selesai load: $PageUrl"
        }

        # Write-Host "Menunggu load selesai: attempt=$Attempt ready=$($data.readyState) loading=$($data.loadingCount) stable=$([int]$stableSeconds)s url=$($data.href)"
    }

    if ($lastData -and -not [string]::IsNullOrWhiteSpace([string]$lastData.h1)) {
        Write-Warning "Timeout load, tetapi h1 sudah ada. Lanjut simpan DOM saat ini: $($lastData.href)"
        return $lastData
    }

    throw "Timeout load dan h1 belum tersedia: $PageUrl"
}

function Save-BlueprintPageAsMhtml {
    param(
        [string]$PageUrl,
        [string]$Folder
    )

    $page = $null
    $socket = $null

    try {
        Write-Host ""
        Write-Host "Buka Edge: $PageUrl"
        $page = Open-DevToolsUrl 'about:blank'
        $socket = [System.Net.WebSockets.ClientWebSocket]::new()
        [void]$socket.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

        [void](Invoke-CdpCommand -Socket $socket -Method 'Page.enable')
        [void](Invoke-CdpCommand -Socket $socket -Method 'Runtime.enable')
        [void](Invoke-CdpCommand -Socket $socket -Method 'Network.enable')

        $data = $null
        for ($attempt = 1; $attempt -le $MaxLoadAttempts; $attempt++) {
            Reset-NetworkState
            if ($attempt -eq 1) {
                [void](Invoke-CdpCommand -Socket $socket -Method 'Page.navigate' -Params @{ url = $PageUrl })
            }
            else {
                Write-Warning "Reload halaman karena metadata belum lengkap: $PageUrl"
                [void](Invoke-CdpCommand -Socket $socket -Method 'Page.reload' -Params @{ ignoreCache = $true })
            }

            try {
                $data = Wait-BlueprintPageReady -Socket $socket -PageUrl $PageUrl -Attempt $attempt
                Assert-PageLoadOk -Data $data
                break
            }
            catch {
                if ($attempt -ge $MaxLoadAttempts) {
                    throw
                }
                Write-Warning $_.Exception.Message
            }
        }

        New-Item -ItemType Directory -Force -Path $Folder | Out-Null
        $filePath = Get-PageFilePath -Folder $Folder -Title $data.h1

        $saved = $false
        if ((Test-Path -LiteralPath $filePath) -and -not $Overwrite) {
            Write-Host "Lewati file yang sudah ada: $(ConvertTo-RelativeRootPath $filePath)"
        }
        else {
            $snapshot = Invoke-CdpCommand -Socket $socket -Method 'Page.captureSnapshot' -Params @{ format = 'mhtml' }
            [System.IO.File]::WriteAllText($filePath, [string]$snapshot.result.data, [System.Text.UTF8Encoding]::new($false))
            $saved = $true
            Write-Host "Simpan MHTML: $(ConvertTo-RelativeRootPath $filePath)"
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
    finally {
        if ($socket) {
            $socket.Dispose()
        }
        if ($page) {
            Close-DevToolsPage -TargetId $page.id
        }
    }
}

if ($WorkerMode) {
    try {
        $workerResult = Save-BlueprintPageAsMhtml -PageUrl $WorkerPageUrl -Folder ([System.IO.Path]::GetFullPath($WorkerSaveFolder))
        [pscustomobject]@{
            WorkerResult = $true
            Success = $true
            OriginalUrl = $workerResult.OriginalUrl
            FinalUrl = $workerResult.FinalUrl
            Title = $workerResult.Title
            FilePath = $workerResult.FilePath
            RelativeFile = (ConvertTo-RelativeRootPath $workerResult.FilePath)
            Saved = $workerResult.Saved
            Actions = @($workerResult.Actions)
            ParentUrl = $workerResult.ParentUrl
            Error = ''
        }
    }
    catch {
        [pscustomobject]@{
            WorkerResult = $true
            Success = $false
            OriginalUrl = $WorkerPageUrl
            FinalUrl = ''
            Title = ''
            FilePath = ''
            RelativeFile = ''
            Saved = $false
            Actions = @()
            ParentUrl = ''
            Error = $_.Exception.Message
        }
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
        $filePath = ConvertTo-LocalPathFromListValue $row.file
        if ([string]::IsNullOrWhiteSpace($filePath) -or -not (Test-Path -LiteralPath $filePath)) {
            continue
        }

        foreach ($urlValue in @($row.url, $row.final_url)) {
            if ([string]::IsNullOrWhiteSpace($urlValue)) {
                continue
            }

            try {
                $map[(Get-CanonicalUrlKey $urlValue)] = [pscustomobject]@{
                    Url = [string]$row.url
                    FinalUrl = [string]$row.final_url
                    FilePath = $filePath
                    Title = [string]$row.title
                    ChildCount = if ($row.child_count -match '^\d+$') { [int]$row.child_count } else { 0 }
                    ParentUrl = [string]$row.parent_url
                }
            }
            catch {
            }
        }
    }

    return $map
}

function Get-LocalResultForTask {
    param(
        $Task,
        [hashtable]$DownloadedMap
    )

    if ($Overwrite -or -not $DownloadedMap) {
        return $null
    }

    $key = Get-CanonicalUrlKey $Task.Url
    if (-not $DownloadedMap.ContainsKey($key)) {
        return $null
    }

    $entry = $DownloadedMap[$key]
    $baseUrl = if ($entry.FinalUrl) { $entry.FinalUrl } else { $Task.Url }
    $result = Get-BlueprintDataFromMhtml -MhtmlPath $entry.FilePath -BaseUrl $baseUrl -FallbackTitle $entry.Title -FallbackParentUrl $entry.ParentUrl
    if (-not $result) {
        return $null
    }

    if ($entry.ChildCount -gt 0 -and @($result.Actions).Count -eq 0) {
        Write-Warning "File lokal ada tapi child link tidak terbaca, fallback ke browser: $($entry.FilePath)"
        return $null
    }

    return $result
}

$stack = New-Object System.Collections.ArrayList
$visited = @{}
$downloadedMap = Get-DownloadedPageMap -Path $ListPath
$downloaded = 0
$started = 0

if ($downloadedMap.Count -gt 0) {
    Write-Host "Index lokal terbaca: $($downloadedMap.Count) URL dari $ListPath"
}

[void]$stack.Add([pscustomobject]@{
    Url = ([Uri]$Url).AbsoluteUri
    SaveFolder = $OutputRoot
    ChildFolder = $OutputRoot
})

function Add-ChildTasks {
    param(
        [System.Collections.ArrayList]$Queue,
        [hashtable]$Seen,
        $Task,
        $Result
    )

    $actions = @($Result.Actions)
    for ($index = $actions.Count - 1; $index -ge 0; $index--) {
        $action = $actions[$index]
        if ([string]::IsNullOrWhiteSpace([string]$action.url)) {
            continue
        }

        $key = Get-CanonicalUrlKey ([string]$action.url)
        if ($Seen.ContainsKey($key)) {
            continue
        }

        $childFolderName = ConvertTo-SafeSegment -Value $action.name -MaxLength 90
        [void]$Queue.Add([pscustomobject]@{
            Url = [string]$action.url
            SaveFolder = $Task.ChildFolder
            ChildFolder = (Join-Path $Task.ChildFolder $childFolderName)
        })
    }
}

function Write-ListEntry {
    param($Result)

    $relativeFile = if ($Result.RelativeFile) { $Result.RelativeFile } else { ConvertTo-RelativeRootPath $Result.FilePath }
    Add-Content -LiteralPath $ListPath -Value "$($Result.OriginalUrl)`t$($Result.FinalUrl)`t$relativeFile`t$($Result.Title)`t$(@($Result.Actions).Count)`t$($Result.ParentUrl)" -Encoding UTF8

    foreach ($urlValue in @($Result.OriginalUrl, $Result.FinalUrl)) {
        if ([string]::IsNullOrWhiteSpace([string]$urlValue)) {
            continue
        }

        try {
            $downloadedMap[(Get-CanonicalUrlKey ([string]$urlValue))] = [pscustomobject]@{
                Url = [string]$Result.OriginalUrl
                FinalUrl = [string]$Result.FinalUrl
                FilePath = [string]$Result.FilePath
                Title = [string]$Result.Title
                ChildCount = @($Result.Actions).Count
                ParentUrl = [string]$Result.ParentUrl
            }
        }
        catch {
        }
    }
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

function Invoke-LocalTaskIfAvailable {
    param(
        [System.Collections.ArrayList]$Queue,
        [hashtable]$Seen,
        [hashtable]$DownloadedMap,
        $Task
    )

    $localResult = Get-LocalResultForTask -Task $Task -DownloadedMap $DownloadedMap
    if (-not $localResult) {
        return $false
    }

    Write-Host "Baca lokal: $(ConvertTo-RelativeRootPath $localResult.FilePath)"
    Add-ChildTasks -Queue $Queue -Seen $Seen -Task $Task -Result $localResult
    return $true
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
        RetryCount = $retryCount
    })
}

function Start-PageWorkerJob {
    param($Task)

    Ensure-Edge
    Write-Host "Mulai job: $($Task.Url)"

    $scriptPath = $PSCommandPath
    $initialization = {
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    }

    return Start-Job -InitializationScript $initialization -ScriptBlock {
        param(
            [string]$ScriptPath,
            [int]$BrowserPort,
            [string]$PageUrl,
            [string]$SaveFolder,
            [int]$BrowserPollSeconds,
            [int]$PageIdleSeconds,
            [int]$PageLoadTimeoutSeconds,
            [int]$MaxLoadAttempts,
            [bool]$OverwriteFlag
        )

        & $ScriptPath `
            -WorkerMode `
            -WorkerBrowserPort $BrowserPort `
            -WorkerPageUrl $PageUrl `
            -WorkerSaveFolder $SaveFolder `
            -BrowserPollSeconds $BrowserPollSeconds `
            -PageIdleSeconds $PageIdleSeconds `
            -PageLoadTimeoutSeconds $PageLoadTimeoutSeconds `
            -MaxLoadAttempts $MaxLoadAttempts `
            -Overwrite:$OverwriteFlag
    } -ArgumentList @(
        $scriptPath,
        $script:BrowserPort,
        [string]$Task.Url,
        [string]$Task.SaveFolder,
        $BrowserPollSeconds,
        $PageIdleSeconds,
        $PageLoadTimeoutSeconds,
        $MaxLoadAttempts,
        $Overwrite.IsPresent
    )
}

if ($ParallelPages -le 1) {
    while ($stack.Count -gt 0) {
        if (-not (Test-CanStartMore -StartedCount $started)) {
            Write-Host "MaxPages tercapai: $MaxPages"
            break
        }

        $task = Get-NextTask -Queue $stack -Seen $visited
        if (-not $task) {
            break
        }

        if (Invoke-LocalTaskIfAvailable -Queue $stack -Seen $visited -DownloadedMap $downloadedMap -Task $task) {
            continue
        }

        $started++
        try {
            $result = Save-BlueprintPageAsMhtml -PageUrl $task.Url -Folder $task.SaveFolder
            $downloaded++
            Write-ListEntry -Result $result
            Add-ChildTasks -Queue $stack -Seen $visited -Task $task -Result $result
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

    while ($stack.Count -gt 0) {
        $batch = New-Object System.Collections.ArrayList

        while ($batch.Count -lt $ParallelPages -and (Test-CanStartMore -StartedCount $started)) {
            $task = Get-NextTask -Queue $stack -Seen $visited
            if (-not $task) {
                break
            }

            if (Invoke-LocalTaskIfAvailable -Queue $stack -Seen $visited -DownloadedMap $downloadedMap -Task $task) {
                continue
            }

            $job = Start-PageWorkerJob -Task $task
            [void]$batch.Add([pscustomobject]@{
                Job = $job
                Task = $task
            })
            $started++
        }

        if ($batch.Count -eq 0) {
            if (-not (Test-CanStartMore -StartedCount $started) -and $MaxPages -gt 0) {
                Write-Host "MaxPages tercapai: $MaxPages"
            }
            break
        }

        Write-Host "Menunggu batch selesai: $($batch.Count) job"
        [void](Wait-Job -Job @($batch | ForEach-Object { $_.Job }))

        foreach ($item in @($batch)) {
            $received = @(Receive-Job -Job $item.Job -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)
            $result = $received | Where-Object { $_.PSObject.Properties['WorkerResult'] } | Select-Object -Last 1

            if ($result -and $result.Success) {
                $downloaded++
                Write-ListEntry -Result $result
                Add-ChildTasks -Queue $stack -Seen $visited -Task $item.Task -Result $result

                $status = if ($result.Saved) { 'Simpan' } else { 'Lewati existing' }
                Write-Host "${status}: $($result.RelativeFile)"
            }
            elseif ($result) {
                if ($started -gt 0) {
                    $started--
                }
                Add-FailedTaskBack -Queue $stack -Seen $visited -Task $item.Task -ErrorMessage $result.Error
            }
            else {
                if ($started -gt 0) {
                    $started--
                }
                Add-FailedTaskBack -Queue $stack -Seen $visited -Task $item.Task -ErrorMessage 'job tidak mengembalikan hasil'
            }

            Remove-Job -Job $item.Job -Force
        }
    }
}

Write-Host ""
Write-Host "Selesai. Total halaman tersimpan/diproses: $downloaded"
Write-Host "Daftar hasil: $ListPath"
pause
