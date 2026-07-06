param(
    [string]$MhtmlRoot = (Join-Path $PSScriptRoot 'mhtml'),
    [int]$BrowserPollSeconds = 1,
    [double]$PageIdleSeconds = 0.1,
    [int]$PageLoadTimeoutSeconds = 60,
    [int]$MaxLoadAttempts = 100000,
    [int]$ParallelPages = 4,
    [int]$BlockCodeParallelism = 10,
    [int]$MaxPages = 0,
    [switch]$Overwrite,
    [switch]$DryRun,
    [switch]$LoadImages,
    [switch]$NoPause,
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
$BlockCodeParallelism = [Math]::Min(100, [Math]::Max(1, $BlockCodeParallelism))

$MinimumMhtmlBytes = 650KB
$MhtmlRoot = [System.IO.Path]::GetFullPath($MhtmlRoot)
$script:BrowserPort = if ($WorkerMode) { $WorkerBrowserPort } else { $null }
$script:BrowserProfileDir = Join-Path $PSScriptRoot '.browser-profile'
$script:CdpCommandId = 0
$script:MainDocumentStatus = $null
$script:MainDocumentStatusText = ''
$script:MainDocumentFailedText = ''
$script:MainDocumentRequestId = ''
$script:MainDocumentFrameId = ''
$script:KnownUrlMapCache = @{}
$script:XmlSourceFilesForLinkIndex = @()
$script:UnrealApplicationVersionFallbacks = @('5.7', '5.6', '5.5', '5.4', '5.3')
$script:MetaHumanApplicationVersionFallbacks = @('5.7', '5.6', '5.0-5.5')

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
    New-Item -ItemType Directory -Force -Path $MhtmlRoot | Out-Null
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

function Initialize-BrowserProfile {
    param([string]$ProfileDir)

    if (Test-Path -LiteralPath $ProfileDir) {
        return
    }

    $defaultProfileDir = Join-Path $ProfileDir 'Default'
    New-Item -ItemType Directory -Force -Path $defaultProfileDir | Out-Null

    $preferences = [ordered]@{
        background_mode = [ordered]@{ enabled = $false }
        browser = [ordered]@{ has_seen_welcome_page = $true }
        download = [ordered]@{
            directory_upgrade = $true
            prompt_for_download = $false
        }
        edge = [ordered]@{
            sleeping_tabs = [ordered]@{
                enabled = $false
                fade_tabs = $false
            }
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
        plugins = [ordered]@{ always_open_pdf_externally = $true }
    }

    $localState = [ordered]@{
        background_mode = [ordered]@{ enabled = $false }
        browser = [ordered]@{ enabled_labs_experiments = @() }
    }

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Join-Path $defaultProfileDir 'Preferences'), ($preferences | ConvertTo-Json -Depth 20 -Compress), $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $ProfileDir 'Local State'), ($localState | ConvertTo-Json -Depth 20 -Compress), $utf8NoBom)
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
        (Join-Path $PSScriptRoot ".browser-profile-$PID-$(Get-Date -Format 'yyyyMMddHHmmss')")
    )) {
        $script:BrowserPort = Get-FreeTcpPort
        Initialize-BrowserProfile -ProfileDir $profileDir

        $arguments = @(
            "--remote-debugging-port=$($script:BrowserPort)",
            "--user-data-dir=$profileDir",
            '--disable-background-mode',
            '--disable-background-timer-throttling',
            '--disable-renderer-backgrounding',
            '--disable-features=msSleepingTabs,msSleepingTabsAvailable,msFadeSleepingTabs,msEdgeSleepingTabs,EdgeSleepingTabs,TabFreeze,TabDiscarding,AutomaticTabDiscarding,PerformanceDetector',
            '--no-first-run',
            '--start-maximized',
            '--new-window',
            'about:blank'
        )

        Start-Process -FilePath $edgePath -ArgumentList $arguments -WindowStyle Maximized | Out-Null

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
            Handle-CdpEvent -Socket $Socket -Message $response
        }
    } while ($response.id -ne $id)

    if ($response.error) {
        throw "$Method gagal: $($response.error.message)"
    }

    return $response
}

function Send-CdpCommandNoWait {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [string]$Method,
        [hashtable]$Params = @{}
    )

    $script:CdpCommandId++
    $message = @{
        id = $script:CdpCommandId
        method = $Method
        params = $Params
    } | ConvertTo-Json -Depth 30 -Compress

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($message)
    $segment = [ArraySegment[byte]]::new($bytes)
    [void]$Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
}

function Reset-NetworkState {
    $script:MainDocumentStatus = $null
    $script:MainDocumentStatusText = ''
    $script:MainDocumentFailedText = ''
    $script:MainDocumentRequestId = ''
    $script:MainDocumentFrameId = ''
}

function Update-NetworkStateFromEvent {
    param($Message)

    if (-not $Message -or -not $Message.method) {
        return
    }

    if ($Message.method -eq 'Network.requestWillBeSent' -and $Message.params.type -eq 'Document') {
        $frameId = [string]$Message.params.frameId
        if ($script:MainDocumentFrameId -and $frameId -and $frameId -ne $script:MainDocumentFrameId) {
            return
        }
        if (-not $script:MainDocumentRequestId -or ($script:MainDocumentFrameId -and $frameId -eq $script:MainDocumentFrameId)) {
            $script:MainDocumentRequestId = [string]$Message.params.requestId
        }
        return
    }

    if ($Message.method -eq 'Network.responseReceived' -and $Message.params.type -eq 'Document') {
        $frameId = [string]$Message.params.frameId
        if ($script:MainDocumentFrameId -and $frameId -and $frameId -ne $script:MainDocumentFrameId) {
            return
        }
        if ($script:MainDocumentRequestId -and ([string]$Message.params.requestId) -ne $script:MainDocumentRequestId) {
            return
        }
        $script:MainDocumentRequestId = [string]$Message.params.requestId
        $script:MainDocumentStatus = [int]$Message.params.response.status
        $script:MainDocumentStatusText = [string]$Message.params.response.statusText
        return
    }

    if ($Message.method -eq 'Network.loadingFailed') {
        $requestId = [string]$Message.params.requestId
        $frameId = [string]$Message.params.frameId
        $errorText = [string]$Message.params.errorText
        $isDocumentFailure = ([string]$Message.params.type) -eq 'Document'
        $isKnownMainDocument = $script:MainDocumentRequestId -and $requestId -eq $script:MainDocumentRequestId
        $isMainFrameDocument = $script:MainDocumentFrameId -and $frameId -and $frameId -eq $script:MainDocumentFrameId

        if ($isKnownMainDocument -or ($isDocumentFailure -and $isMainFrameDocument)) {
            if ($requestId) {
                $script:MainDocumentRequestId = $requestId
            }
            $script:MainDocumentFailedText = $errorText
        }
    }
}

function Handle-CdpEvent {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        $Message
    )

    Update-NetworkStateFromEvent -Message $Message

    if ($Message -and $Message.method -eq 'Fetch.requestPaused') {
        $requestId = [string]$Message.params.requestId
        if ([string]::IsNullOrWhiteSpace($requestId)) {
            return
        }

        $resourceType = [string]$Message.params.resourceType
        $requestUrl = [string]$Message.params.request.url
        $shouldBlock = -not $LoadImages -and (
            $resourceType -eq 'Image' -or
            $resourceType -eq 'Media' -or
            $requestUrl -match '(?i)/community/api/(learning|documentation|user_profiles)/image/' -or
            $requestUrl -match '(?i)[?&]resizing_type='
        )

        $method = if ($shouldBlock) { 'Fetch.failRequest' } else { 'Fetch.continueRequest' }
        $params = if ($shouldBlock) {
            @{
                requestId = $requestId
                errorReason = 'BlockedByClient'
            }
        }
        else {
            @{ requestId = $requestId }
        }

        try {
            Send-CdpCommandNoWait -Socket $Socket -Method $method -Params $params
        }
        catch {
            Write-Warning "Fetch handler gagal untuk ${requestUrl}: $($_.Exception.Message)"
        }
    }
}

function Update-NetworkStateFromNavigateResult {
    param($Response)

    if (-not $Response -or -not $Response.result) {
        return
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Response.result.frameId)) {
        $script:MainDocumentFrameId = [string]$Response.result.frameId
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Response.result.errorText)) {
        $script:MainDocumentFailedText = [string]$Response.result.errorText
    }
}

function Get-MhtmlCaptureBlockerExpression {
    return @'
(() => {
  window.__mhtmlCaptureBlockerNetworkOnly = true;
})()
'@
}

function Test-IgnorableNavigationFailure {
    param([string]$ErrorText)

    return ([string]$ErrorText) -eq 'net::ERR_ABORTED'
}

function Set-UrlApplicationVersion {
    param(
        [string]$PageUrl,
        [string]$Version
    )

    try {
        $builder = [System.UriBuilder]::new($PageUrl)
        $queryItems = New-Object System.Collections.ArrayList
        $query = $builder.Query.TrimStart('?')
        if (-not [string]::IsNullOrWhiteSpace($query)) {
            foreach ($part in ($query -split '&')) {
                if ([string]::IsNullOrWhiteSpace($part)) {
                    continue
                }

                $name = ($part -split '=', 2)[0]
                if ($name -ieq 'application_version') {
                    continue
                }

                [void]$queryItems.Add($part)
            }
        }

        [void]$queryItems.Add("application_version=$Version")
        $builder.Query = ($queryItems -join '&')
        return $builder.Uri.AbsoluteUri
    }
    catch {
        $separator = if ($PageUrl.Contains('?')) { '&' } else { '?' }
        return "$PageUrl${separator}application_version=$Version"
    }
}

function Remove-UrlApplicationVersion {
    param([string]$PageUrl)

    if ([string]::IsNullOrWhiteSpace($PageUrl)) {
        return ''
    }

    try {
        $builder = [System.UriBuilder]::new($PageUrl)
        $queryItems = New-Object System.Collections.ArrayList
        $query = $builder.Query.TrimStart('?')
        if (-not [string]::IsNullOrWhiteSpace($query)) {
            foreach ($part in ($query -split '&')) {
                if ([string]::IsNullOrWhiteSpace($part)) {
                    continue
                }

                $name = ($part -split '=', 2)[0]
                if ($name -ieq 'application_version') {
                    continue
                }

                [void]$queryItems.Add($part)
            }
        }

        $builder.Query = ($queryItems -join '&')
        return $builder.Uri.AbsoluteUri
    }
    catch {
        return ([string]$PageUrl -replace '([?&])application_version=[^&]*&?', '$1' -replace '[?&]$', '')
    }
}

function Get-PageUrlCandidates {
    param([string]$PageUrl)

    $fallbackVersions = if ($PageUrl -match '(?i)://[^/]+/documentation/metahuman(?:/|$)') {
        @($script:MetaHumanApplicationVersionFallbacks)
    }
    else {
        @($script:UnrealApplicationVersionFallbacks)
    }

    $seen = @{}
    $candidates = New-Object System.Collections.ArrayList
    foreach ($candidate in @($PageUrl) + @($fallbackVersions | ForEach-Object { Set-UrlApplicationVersion -PageUrl $PageUrl -Version $_ })) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $key = $candidate.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }

        $seen[$key] = $true
        [void]$candidates.Add($candidate)
    }

    return @($candidates)
}

function Test-VersionDocumentationRootUrl {
    param([string]$PageUrl)

    if ([string]::IsNullOrWhiteSpace($PageUrl)) {
        return $false
    }

    try {
        $uri = [Uri]$PageUrl
        $path = $uri.AbsolutePath.TrimEnd('/').ToLowerInvariant()
        return (
            $path -match '/documentation/unreal-engine/unreal-engine-5-\d+-documentation$' -or
            $path -eq '/documentation/metahuman/metahuman-documentation'
        )
    }
    catch {
        return $false
    }
}

function Get-MhtmlSnapshotExpression {
    return @'
(() => {
  const normalize = (value) => (value || '').replace(/\s+/g, ' ').trim();
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
  const loadingCount = loadingSelectors
    .flatMap(selector => Array.from(document.querySelectorAll(selector)))
    .filter(isVisible).length;
  const hotToastErrors = Array.from(document.querySelectorAll('hot-toast-container hot-toast, hot-toast'))
    .map(toast => normalize(toast.textContent || toast.innerText || ''))
    .filter(text => /\berror\b/i.test(text));
  const h1 = document.querySelector('h1');
  const htmlLength = document.documentElement?.outerHTML?.length || 0;
  const hasContentMeta = !!document.querySelector('div.content-item-header-meta');

  return JSON.stringify({
    href: location.href,
    readyState: document.readyState,
    title: document.title || '',
    h1: normalize(h1?.textContent || ''),
    hasH1: !!h1,
    hasContentMeta,
    hotToastErrors,
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
        [string]$Expression,
        [switch]$AwaitPromise
    )

    $params = @{
        expression = $Expression
        returnByValue = $true
    }
    if ($AwaitPromise.IsPresent) {
        $params.awaitPromise = $true
    }

    $response = Invoke-CdpCommand -Socket $Socket -Method 'Runtime.evaluate' -Params $params

    if ($response.result.exceptionDetails) {
        throw "Runtime evaluate gagal: $($response.result.exceptionDetails.text)"
    }

    return [string]$response.result.result.value
}

function Wait-MhtmlPageReady {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [string]$PageUrl,
        [int]$Attempt
    )

    $deadline = (Get-Date).AddSeconds($PageLoadTimeoutSeconds)
    $stableSince = $null
    $lastData = $null

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $BrowserPollSeconds

        $json = Invoke-PageEval -Socket $Socket -Expression (Get-MhtmlSnapshotExpression)
        $data = $json | ConvertFrom-Json
        $lastData = $data

        if (-not $data.isLoading -and $data.htmlLength -gt 0) {
            if (-not $stableSince) {
                $stableSince = Get-Date
            }

            if (((Get-Date) - $stableSince).TotalSeconds -ge $PageIdleSeconds) {
                return $data
            }
        }
        else {
            $stableSince = $null
        }
    }

    $title = if ($lastData) { [string]$lastData.title } else { '' }
    $h1 = if ($lastData) { [string]$lastData.h1 } else { '' }
    throw "Timeout load halaman attempt #${Attempt}: $PageUrl title='$title' h1='$h1'"
}

function Get-MhtmlSwitchDiscoveryExpression {
    return @'
(async () => {
  const delay = (ms) => new Promise(resolve => setTimeout(resolve, ms));
  const normalize = (value) => (value || '').replace(/\s+/g, ' ').trim();
  const visible = (el) => {
    if (!el) return false;
    const style = getComputedStyle(el);
    const rect = el.getBoundingClientRect();
    return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
  };
  const mapIcon = (el) => {
    const cls = (el?.className || '').toString().toLowerCase();
    if (cls.includes('icon-windows')) return 'Windows';
    if (cls.includes('icon-linux')) return 'Linux';
    if (cls.includes('icon-apple') || cls.includes('icon-mac') || cls.includes('icon-macos')) return 'Mac';
    if (cls.includes('icon-blueprint')) return 'Blueprint';
    if (cls.includes('icon-cpp') || cls.includes('icon-cplusplus')) return 'C++';
    return '';
  };
  const unique = (items) => {
    const seen = new Set();
    return items.map(normalize).filter(Boolean).filter(item => {
      const key = item.toLowerCase();
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  };
  const readDropdownOptions = async (control) => {
    const openers = Array.from(control.querySelectorAll('.ng-select-container, .ng-arrow-wrapper, input[role="combobox"], ng-select, .ng-select, [role="combobox"], button'));
    if (openers.length === 0) openers.push(control);
    for (const opener of openers) {
      try {
        opener.focus?.();
        opener.dispatchEvent(new MouseEvent('pointerdown', { bubbles: true, cancelable: true, view: window }));
        opener.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window }));
        opener.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, view: window }));
        opener.click();
        opener.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', altKey: true, bubbles: true, cancelable: true }));
      } catch {}
      await delay(150);
      if (document.querySelector('.ng-dropdown-panel .ng-option')) break;
    }
    let optionNodes = [];
    for (let attempt = 0; attempt < 10; attempt++) {
      optionNodes = Array.from(document.querySelectorAll('.ng-dropdown-panel .ng-option'));
      if (optionNodes.length > 0) break;
      await delay(150);
    }
    const options = optionNodes
      .filter(option => !option.classList.contains('ng-option-disabled'))
      .map(option => normalize(option.innerText || option.textContent || option.getAttribute('aria-label') || option.getAttribute('title') || mapIcon(option.querySelector('.block-switch-option-icon, [class*="icon-"]')) || ''));
    try {
      document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    } catch {}
    return unique(options.filter(option => option && !/loading|no items|no results/i.test(option)));
  };
  const fallbackOptionsFor = (root) => {
    const roots = root ? [root] : Array.from(document.querySelectorAll('block-switch-view'));
    const labels = [];
    for (const item of roots) {
      for (const icon of Array.from(item.querySelectorAll('.block-switch-option-icon, [class*="icon-"]'))) {
        const label = mapIcon(icon);
        if (label) labels.push(label);
      }
    }
    return unique(labels);
  };
  const controls = Array.from(document.querySelectorAll('block-switch-control'));
  const groups = [];
  for (let index = 0; index < controls.length; index++) {
    let options = await readDropdownOptions(controls[index]);
    if (options.length === 0) {
      options = fallbackOptionsFor(controls[index]);
    }
    if (options.length > 0) {
      groups.push({ index, options });
    }
  }
  if (groups.length === 0) {
    const fallback = fallbackOptionsFor(null);
    if (fallback.length > 0) {
      groups.push({ index: 0, options: fallback, fallbackOnly: true });
    }
  }
  return JSON.stringify({ hasSwitch: controls.length > 0 || groups.length > 0, groups });
})()
'@
}

function Get-MhtmlSwitchSelectExpression {
    param([string[]]$Options)

    $json = ConvertTo-Json @($Options) -Compress
    return @"
(async () => {
  const requested = $json;
  const delay = (ms) => new Promise(resolve => setTimeout(resolve, ms));
  const normalize = (value) => (value || '').replace(/\s+/g, ' ').trim();
  const visible = (el) => {
    if (!el) return false;
    const style = getComputedStyle(el);
    const rect = el.getBoundingClientRect();
    return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
  };
  const labelOf = (el) => normalize(el?.innerText || el?.textContent || el?.getAttribute('aria-label') || el?.getAttribute('title') || mapIcon(el?.querySelector?.('.block-switch-option-icon, [class*="icon-"]')) || mapIcon(el) || '');
  const mapIcon = (el) => {
    const cls = (el?.className || '').toString().toLowerCase();
    if (cls.includes('icon-windows')) return 'Windows';
    if (cls.includes('icon-linux')) return 'Linux';
    if (cls.includes('icon-apple') || cls.includes('icon-mac') || cls.includes('icon-macos')) return 'Mac';
    if (cls.includes('icon-blueprint')) return 'Blueprint';
    if (cls.includes('icon-cpp') || cls.includes('icon-cplusplus')) return 'C++';
    return '';
  };
  const clickDropdownOption = async (control, label) => {
    const openers = Array.from(control?.querySelectorAll?.('.ng-select-container, .ng-arrow-wrapper, input[role="combobox"], ng-select, .ng-select, [role="combobox"], button') || []);
    if (openers.length === 0 && control) openers.push(control);
    if (openers.length === 0) return false;
    for (const opener of openers) {
      try {
        opener.focus?.();
        opener.dispatchEvent(new MouseEvent('pointerdown', { bubbles: true, cancelable: true, view: window }));
        opener.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window }));
        opener.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, view: window }));
        opener.click();
        opener.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', altKey: true, bubbles: true, cancelable: true }));
      } catch {}
      await delay(150);
      if (document.querySelector('.ng-dropdown-panel .ng-option')) break;
    }
    const wanted = normalize(label).toLowerCase();
    let options = [];
    for (let attempt = 0; attempt < 10; attempt++) {
      options = Array.from(document.querySelectorAll('.ng-dropdown-panel .ng-option'))
        .filter(option => !option.classList.contains('ng-option-disabled'));
      if (options.length > 0) break;
      await delay(150);
    }
    let match = options.find(option => labelOf(option).toLowerCase() === wanted) ||
      options.find(option => labelOf(option).toLowerCase().includes(wanted));
    if (match) {
      match.scrollIntoView({ block: 'center', inline: 'nearest' });
      try {
        match.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window }));
        match.click();
      } catch {}
      return true;
    }
    try {
      document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    } catch {}
    return false;
  };
  const clickFallbackOption = async (label) => {
    const wanted = normalize(label).toLowerCase();
    const candidates = Array.from(document.querySelectorAll(
      'block-switch-control button, block-switch-control [role="button"], block-switch-control .block-switch-option-icon, block-switch-view button, block-switch-view [role="button"], block-switch-view .block-switch-option-icon'
    )).filter(visible);
    const match = candidates.find(el => {
      const iconLabel = mapIcon(el);
      const textLabel = labelOf(el);
      return iconLabel.toLowerCase() === wanted || textLabel.toLowerCase() === wanted || textLabel.toLowerCase().includes(wanted);
    });
    if (!match) return false;
    const clickable = match.closest('button, [role="button"], .ng-option') || match;
    try {
      clickable.scrollIntoView({ block: 'center', inline: 'nearest' });
      clickable.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window }));
      clickable.click();
      await delay(250);
      return true;
    } catch {
      return false;
    }
  };
  const controls = Array.from(document.querySelectorAll('block-switch-control'));
  const selected = [];
  for (let index = 0; index < requested.length; index++) {
    const label = requested[index];
    let ok = false;
    if (controls[index]) {
      ok = await clickDropdownOption(controls[index], label);
    }
    if (!ok) {
      ok = await clickFallbackOption(label);
    }
    selected.push({ label, selected: ok });
    await delay(900);
  }
  return JSON.stringify({ selected });
})()
"@
}

function Get-MhtmlSnippetPrepareExpression {
    param([int]$Parallelism = 10)

    $safeParallelism = [Math]::Min(100, [Math]::Max(1, $Parallelism))
    return (@'
(async () => {
  const blockCodeParallelism = __MHTML_BLOCK_CODE_PARALLELISM__;
  const delay = (ms) => new Promise(resolve => setTimeout(resolve, ms));
  const normalize = (value) => (value || '').replace(/\s+/g, ' ').trim();
  const mapLimit = async (items, limit, worker) => {
    const results = new Array(items.length);
    let nextIndex = 0;
    const workerCount = Math.min(Math.max(1, limit || 1), items.length);
    await Promise.all(Array.from({ length: workerCount }, async () => {
      while (nextIndex < items.length) {
        const index = nextIndex++;
        results[index] = await worker(items[index], index);
      }
    }));
    return results;
  };
  const visible = (el) => {
    if (!el) return false;
    const style = getComputedStyle(el);
    const rect = el.getBoundingClientRect();
    return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
  };
  const decodeEntities = (value) => {
    let text = value || '';
    const decoder = document.createElement('textarea');
    for (let index = 0; index < 3; index++) {
      decoder.innerHTML = text;
      const decoded = decoder.value;
      if (decoded === text) break;
      text = decoded;
    }
    return text;
  };
  const textOf = (el) => el ? decodeEntities(el.value || el.innerText || el.textContent || '') : '';
  const snippetType = (snippet) => {
    const ownType = normalize([
      snippet.getAttribute?.('snippet-type'),
      snippet.getAttribute?.('data-snippet-type'),
      snippet.getAttribute?.('type')
    ].filter(Boolean).join(' ')).toLowerCase();
    if (ownType === 'blueprint' || snippet.matches?.('[snippet-type="blueprint"], [data-snippet-type="blueprint"]')) return 'blueprint';
    return snippet.querySelector('blueprint-render, .blueprint-render') ? 'blueprint' : 'code';
  };
  const sourceLooksUseful = (text, type) => {
    const value = (text || '').trim();
    if (!value) return false;
    if (/^(copied|copy|copy full snippet)$/i.test(value)) return false;
    return value.length > 0;
  };
  const expectedLineCountFromLabel = (label) => {
    const match = normalize(label).match(/copy full snippet\s*\((\d+)\s+lines?\s+long\)|(\d+)\s+lines?\s+long/i);
    return match ? Number(match[1] || match[2] || 0) : 0;
  };
  const countSourceLines = (source) => {
    const text = (source || '').replace(/\r\n/g, '\n').replace(/\r/g, '\n').replace(/\n$/, '');
    return text.length ? text.split('\n').length : 0;
  };
  const sourceLineCountMatches = (expectedLineCount, sourceLineCount) => {
    return expectedLineCount <= 0 || sourceLineCount === expectedLineCount || sourceLineCount === expectedLineCount - 1;
  };
  const isOwnedBySnippet = (snippet, el) => {
    const ownerSnippet = el.closest?.('block-code-snippet');
    return !ownerSnippet || ownerSnippet === snippet;
  };
  const sourceRootsFor = (snippet) => {
    return [snippet, snippet.parentElement].filter(Boolean);
  };
  const findEpicTextareaSource = (snippet, type) => {
    const nodes = sourceRootsFor(snippet)
      .flatMap(root => Array.from(root.querySelectorAll('textarea:not(.mhtml-full-snippet-source)')))
      .filter(el => isOwnedBySnippet(snippet, el));
    const texts = nodes.map(textOf).filter(text => sourceLooksUseful(text, type));
    texts.sort((a, b) => b.length - a.length);
    return texts[0] || '';
  };
  const findDomSource = (snippet, type) => {
    const nodes = sourceRootsFor(snippet)
      .flatMap(root => Array.from(root.querySelectorAll('[data-full-source], [data-source], [class*="full-source" i], [class*="raw-source" i], .visually-hidden')))
      .filter(el => isOwnedBySnippet(snippet, el) && !el.closest?.('blueprint-render') && !el.classList?.contains('mhtml-full-snippet-source'));
    const texts = nodes.map(el => decodeEntities(
      el.getAttribute('data-full-source') ||
      el.getAttribute('data-source') ||
      textOf(el)
    )).filter(text => sourceLooksUseful(text, type));
    texts.sort((a, b) => b.length - a.length);
    return texts[0] || '';
  };
  const scoreCopyButton = (button) => {
    const label = normalize([
        button.innerText,
        button.textContent,
        button.getAttribute('aria-label'),
        button.getAttribute('title'),
        button.getAttribute('data-tooltip'),
        button.getAttribute('mattooltip')
    ].filter(Boolean).join(' '));
    let score = 0;
    if (/copy/i.test(label)) score += 4;
    if (/full/i.test(label)) score += 3;
    if (/snippet|code/i.test(label)) score += 2;
    if (/expand/i.test(label)) score -= 10;
    if ((button.className || '').toString().match(/copy/i)) score += 2;
    return { button, label, score };
  };
  const clickElement = (button) => {
    if (!button) return false;
    try {
      button.scrollIntoView({ block: 'center', inline: 'nearest' });
      button.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window }));
      button.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, view: window }));
      button.click();
      return true;
    } catch {
      return false;
    }
  };
  const findCopyButton = (snippet) => {
    const actionRoots = Array.from(snippet.querySelectorAll('.block-code-snippet-actions, [class*="snippet-actions" i]'));
    const roots = actionRoots.length ? actionRoots : [snippet];
    const candidates = roots.flatMap(root => Array.from(root.querySelectorAll('button, [role="button"], a')));
    const scored = candidates.filter(visible).map(scoreCopyButton).filter(item => item.score > 0);
    scored.sort((a, b) => b.score - a.score);
    return scored[0] || null;
  };
  const findExpandButton = (root) => {
    const actionRoots = Array.from(root.querySelectorAll?.('.block-code-snippet-actions, [class*="snippet-actions" i], [class*="code-snippet" i]') || []);
    const roots = [root].concat(actionRoots);
    const seen = new Set();
    const candidates = roots.flatMap(item => Array.from(item.querySelectorAll?.('button, [role="button"], a, [aria-expanded="false"]') || []))
      .filter(button => {
        if (seen.has(button)) return false;
        seen.add(button);
        return true;
      })
      .filter(visible)
      .map(button => ({
        button,
        label: normalize([
          button.innerText,
          button.textContent,
          button.getAttribute('aria-label'),
          button.getAttribute('title'),
          button.getAttribute('data-tooltip'),
          button.getAttribute('mattooltip')
        ].filter(Boolean).join(' ')),
        className: (button.className || '').toString(),
        expanded: button.getAttribute?.('aria-expanded') || ''
      }))
      .map(item => {
        let score = 0;
        if (/copy/i.test(item.label) || /copy/i.test(item.className)) score -= 100;
        if (/expand|show\s+(?:more|full|all)|view\s+(?:more|full|all)|read\s+more|more\s+(?:lines|code|snippet)|full\s+snippet/i.test(item.label)) score += 8;
        if (/expand|show-more|show_more|view-more|view_more|more|collapse/i.test(item.className)) score += 3;
        if (item.expanded === 'false') score += 2;
        return Object.assign(item, { score });
      })
      .filter(item => item.score > 0);
    candidates.sort((a, b) => b.score - a.score);
    return candidates[0] || null;
  };
  const codeRenderText = (root) => {
    const nodes = Array.from(root.querySelectorAll?.('pre code, pre') || []);
    if (root.matches?.('pre, code')) nodes.unshift(root);
    return nodes
      .filter(el => !el.closest?.('blueprint-render') && !el.matches?.('textarea'))
      .map(textOf)
      .join('\n');
  };
  const hasLineNumbersAttribute = (root) => {
    const nodes = [root].concat(Array.from(root.querySelectorAll?.('pre, code, [linenumbers], [line-numbers], [data-line-numbers]') || []));
    return nodes.some(node => {
      if (node.hasAttribute?.('linenumbers') || node.hasAttribute?.('line-numbers') || node.hasAttribute?.('data-line-numbers')) return true;
      return Array.from(node.attributes || []).some(attr => /line-?numbers?/i.test(attr.name));
    });
  };
  const tryExpandShortCode = async (root, sourceLineCount, expectedLineCount) => {
    if (expectedLineCount <= 0 || sourceLineCount >= expectedLineCount) {
      return { attempted: false, ok: false, label: '', source: '', sourceLineCount: 0 };
    }
    const expand = findExpandButton(root);
    if (!expand?.button) {
      return { attempted: false, ok: false, label: '', source: '', sourceLineCount: 0 };
    }
    const before = codeRenderText(root);
    const beforeLineCount = countSourceLines(before);
    clickElement(expand.button);
    let bestSource = '';
    let bestLineCount = 0;
    for (let attempt = 0; attempt < 16; attempt++) {
      await delay(150);
      const after = codeRenderText(root);
      const afterLineCount = countSourceLines(after);
      if (sourceLooksUseful(after, 'code') && afterLineCount > bestLineCount) {
        bestSource = after;
        bestLineCount = afterLineCount;
      }
      if (after !== before && sourceLineCountMatches(expectedLineCount, afterLineCount)) {
        return { attempted: true, ok: sourceLineCountMatches(expectedLineCount, afterLineCount), label: expand.label, source: after, sourceLineCount: afterLineCount };
      }
    }
    return { attempted: true, ok: sourceLineCountMatches(expectedLineCount, bestLineCount), label: expand.label, source: bestSource, sourceLineCount: bestLineCount };
  };
  const sourceRootForLooseCopyButton = (button) => {
    let node = button.parentElement;
    for (let depth = 0; node && depth < 8; depth++, node = node.parentElement) {
      if (node.closest?.('block-code-snippet')) return null;
      if (
        node.querySelector?.('textarea:not(.mhtml-full-snippet-source)') ||
        node.querySelector?.('blueprint-render, .blueprint-render') ||
        node.querySelector?.('pre.block-code-snippet-plain, pre code')
      ) {
        return node;
      }
    }
    return null;
  };
  const findLooseCopyTargets = () => {
    const buttons = Array.from(document.querySelectorAll('button, [role="button"], a'))
      .filter(button => !button.closest?.('block-code-snippet') && !button.closest?.('pre.block-code-snippet-plain'))
      .filter(visible)
      .map(scoreCopyButton)
      .filter(item => item.score > 0 && (/copy/i.test(item.label) || expectedLineCountFromLabel(item.label) > 0));
    const seen = new Set();
    const targets = [];
    for (const item of buttons.sort((a, b) => b.score - a.score)) {
      const root = sourceRootForLooseCopyButton(item.button);
      if (!root || seen.has(root)) continue;
      seen.add(root);
      targets.push({ root, button: item.button, label: item.label });
    }
    return targets;
  };
  const waitForSnippetSource = async (snippet, type) => {
    let bestSource = '';
    let fromTextarea = false;
    for (let attempt = 0; attempt < 24; attempt++) {
      await delay(150);
      const textareaSource = findEpicTextareaSource(snippet, type);
      if (sourceLooksUseful(textareaSource, type)) {
        return { source: textareaSource, fromTextarea: true };
      }

      const domSource = findDomSource(snippet, type);
      if (sourceLooksUseful(domSource, type)) {
        bestSource = domSource;
        fromTextarea = false;
      }
    }

    return { source: bestSource, fromTextarea };
  };
  const writeTextareaSource = (textarea, source, type, metadata = {}) => {
    textarea.className = 'mhtml-full-snippet-source';
    textarea.setAttribute('aria-hidden', 'true');
    textarea.setAttribute('readonly', 'readonly');
    textarea.setAttribute('tabindex', '-1');
    textarea.setAttribute('data-mhtml-full-source', 'true');
    textarea.setAttribute('data-snippet-type', type);
    textarea.setAttribute('data-source-length', String((source || '').length));
    textarea.setAttribute('data-source-lines', String(countSourceLines(source)));
    if (metadata.expectedLineCount > 0) textarea.setAttribute('data-expected-lines', String(metadata.expectedLineCount));
    if (metadata.buttonLabel) textarea.setAttribute('data-copy-button-label', metadata.buttonLabel);
    textarea.style.cssText = 'display:block !important; position:absolute !important; left:-100000px !important; top:auto !important; width:1px !important; height:1px !important; opacity:0 !important; pointer-events:none !important;';
    textarea.value = source || '';
    textarea.defaultValue = source || '';
    textarea.textContent = source || '';
    return textarea;
  };
  const findExistingStaticSourceElement = (root, source) => {
    const wanted = (source || '').trim();
    if (!wanted) return null;
    const candidates = Array.from(root.querySelectorAll('[data-full-source], [data-source], [class*="full-source" i], [class*="raw-source" i], .visually-hidden'))
      .filter(el => !el.matches?.('textarea') && !el.closest?.('blueprint-render') && !el.classList?.contains('mhtml-full-snippet-source'));
    return candidates.find(el => textOf(el).trim() === wanted) || null;
  };
  const replaceExistingSourceElement = (el, source, type, metadata = {}) => {
    if (!el?.parentNode) return null;
    const textarea = document.createElement('textarea');
    writeTextareaSource(textarea, source, type, metadata);
    el.replaceWith(textarea);
    return textarea;
  };
  const injectSnippetSource = (snippet, source, type, metadata = {}) => {
    if (!sourceLooksUseful(source, type)) return false;
    const existing = findExistingStaticSourceElement(snippet, source);
    if (existing) {
      replaceExistingSourceElement(existing, source, type, metadata);
      return true;
    }
    let textarea = Array.from(snippet.children).find(el => el.matches?.('textarea.mhtml-full-snippet-source'));
    if (!textarea) {
      textarea = document.createElement('textarea');
      snippet.appendChild(textarea);
    }
    writeTextareaSource(textarea, source, type, metadata);
    return true;
  };
  const legacySourceFor = (pre) => {
    const next = pre.nextElementSibling;
    if (next?.matches?.('textarea:not(.mhtml-full-snippet-source)')) {
      const textareaText = textOf(next);
      if (sourceLooksUseful(textareaText, 'code')) return { source: textareaText, fromTextarea: true };
    }
    const code = pre.querySelector('code') || pre;
    return { source: textOf(code), fromTextarea: false };
  };
  const injectLegacySource = (pre, source) => {
    if (!sourceLooksUseful(source, 'code')) return false;
    let textarea = pre.nextElementSibling?.matches?.('textarea') ? pre.nextElementSibling : null;
    if (!textarea) {
      textarea = document.createElement('textarea');
      pre.insertAdjacentElement('afterend', textarea);
    }
    writeTextareaSource(textarea, source, 'code', {});
    const duplicate = textarea.nextElementSibling;
    if (duplicate?.matches?.('textarea:not(.mhtml-full-snippet-source)') && !textOf(duplicate).trim()) {
      duplicate.remove();
    }
    return true;
  };
  const processSnippet = async (snippet, index) => {
    const expectedType = snippetType(snippet);
    const copy = findCopyButton(snippet);
    const button = copy?.button || null;
    const buttonLabel = copy?.label || '';
    const expectedLineCount = expectedLineCountFromLabel(buttonLabel);
    if (button) clickElement(button);

    const waitResult = await waitForSnippetSource(snippet, expectedType);
    const source = waitResult.source || '';
    const type = expectedType;
    const sourceLineCount = countSourceLines(source);
    const expandResult = type === 'code' ? await tryExpandShortCode(snippet, sourceLineCount, expectedLineCount) : { attempted: false, ok: false, label: '', source: '', sourceLineCount: 0 };
    const injected = injectSnippetSource(snippet, source, type, { expectedLineCount, buttonLabel });
    const filled = sourceLooksUseful(source, type);
    const lineCountOk = sourceLineCountMatches(expectedLineCount, sourceLineCount) ||
      (type === 'blueprint' && expectedLineCount > 0 && sourceLineCount < expectedLineCount && filled) ||
      (type === 'code' && expectedLineCount > 0 && sourceLineCount < expectedLineCount && expandResult.ok && filled) ||
      (type === 'code' && expectedLineCount > 0 && sourceLineCount < expectedLineCount && !expandResult.attempted && filled);
    return {
      index,
      type,
      clicked: !!button,
      buttonLabel,
      filled,
      injected,
      fromTextarea: !!waitResult.fromTextarea,
      sourceLength: (source || '').length,
      expectedLineCount,
      sourceLineCount,
      lineCountOk,
      expandAttempted: !!expandResult.attempted,
      expandOk: !!expandResult.ok,
      expandLabel: expandResult.label || '',
      sourceHead: normalize((source || '').split(/\r?\n/).find(line => line.trim()) || '').slice(0, 160)
    };
  };
  const processLegacySnippet = (pre, offset, index) => {
    const found = legacySourceFor(pre);
    const source = found.source || '';
    const sourceLineCount = countSourceLines(source);
    const injected = injectLegacySource(pre, source);
    return {
      index: offset + index,
      type: 'code',
      legacy: true,
      clicked: false,
      buttonLabel: '',
      filled: sourceLooksUseful(source, 'code'),
      injected,
      fromTextarea: !!found.fromTextarea,
      sourceLength: (source || '').length,
      expectedLineCount: 0,
      sourceLineCount,
      lineCountOk: true,
      sourceHead: normalize((source || '').split(/\r?\n/).find(line => line.trim()) || '').slice(0, 160)
    };
  };
  const processLooseCopyTarget = async (target, offset, index) => {
    const root = target.root;
    const type = snippetType(root);
    const buttonLabel = target.label || '';
    const expectedLineCount = expectedLineCountFromLabel(buttonLabel);
    clickElement(target.button);

    const waitResult = await waitForSnippetSource(root, type);
    const source = waitResult.source || '';
    const sourceLineCount = countSourceLines(source);
    const expandResult = type === 'code' ? await tryExpandShortCode(root, sourceLineCount, expectedLineCount) : { attempted: false, ok: false, label: '', source: '', sourceLineCount: 0 };
    const injected = injectSnippetSource(root, source, type, { expectedLineCount, buttonLabel });
    const filled = sourceLooksUseful(source, type);
    const lineCountOk = sourceLineCountMatches(expectedLineCount, sourceLineCount) ||
      (type === 'blueprint' && expectedLineCount > 0 && sourceLineCount < expectedLineCount && filled) ||
      (type === 'code' && expectedLineCount > 0 && sourceLineCount < expectedLineCount && expandResult.ok && filled) ||
      (type === 'code' && expectedLineCount > 0 && sourceLineCount < expectedLineCount && !expandResult.attempted && filled);
    return {
      index: offset + index,
      type,
      looseCopy: true,
      clicked: true,
      buttonLabel,
      filled,
      injected,
      fromTextarea: !!waitResult.fromTextarea,
      sourceLength: (source || '').length,
      expectedLineCount,
      sourceLineCount,
      lineCountOk,
      expandAttempted: !!expandResult.attempted,
      expandOk: !!expandResult.ok,
      expandLabel: expandResult.label || '',
      sourceHead: normalize((source || '').split(/\r?\n/).find(line => line.trim()) || '').slice(0, 160)
    };
  };
  const snippets = Array.from(document.querySelectorAll('block-code-snippet'));
  const snippetResults = await mapLimit(snippets, blockCodeParallelism, processSnippet);
  const legacySnippets = Array.from(document.querySelectorAll('pre.block-code-snippet-plain'))
    .filter(pre => !pre.closest('block-code-snippet'));
  const legacyResults = legacySnippets.map((pre, index) => processLegacySnippet(pre, snippets.length, index));
  const looseTargets = findLooseCopyTargets();
  const looseResults = await mapLimit(looseTargets, blockCodeParallelism, (target, index) => processLooseCopyTarget(target, snippets.length + legacySnippets.length, index));
  const results = snippetResults.concat(legacyResults, looseResults);
  return JSON.stringify({ snippetCount: results.length, blockSnippetCount: snippets.length, legacySnippetCount: legacySnippets.length, looseCopySnippetCount: looseTargets.length, blockCodeParallelism, results });
})()
'@).Replace('__MHTML_BLOCK_CODE_PARALLELISM__', [string]$safeParallelism)
}

function Get-SwitchOptionCombinations {
    param([object[]]$Groups)

    $combinations = New-Object System.Collections.ArrayList
    [void]$combinations.Add([pscustomobject]@{ Options = @() })

    foreach ($group in @($Groups)) {
        $options = @($group.options | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($options.Count -eq 0) {
            continue
        }

        $next = New-Object System.Collections.ArrayList
        foreach ($prefix in @($combinations)) {
            foreach ($option in $options) {
                [void]$next.Add([pscustomobject]@{ Options = @($prefix.Options) + @([string]$option) })
            }
        }
        $combinations = $next
    }

    if ($combinations.Count -eq 0) {
        [void]$combinations.Add([pscustomobject]@{ Options = @() })
    }

    return @($combinations)
}

function Get-MhtmlVariantFilePath {
    param(
        [string]$BaseFilePath,
        [string[]]$Options
    )

    if (-not $Options -or $Options.Count -eq 0) {
        return $BaseFilePath
    }

    $folder = [System.IO.Path]::GetDirectoryName($BaseFilePath)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($BaseFilePath)
    $suffix = (($Options | ForEach-Object { " [--$(ConvertTo-SafeSegment -Value ([string]$_) -MaxLength 40)--]" }) -join '')
    return (Join-Path $folder "$baseName$suffix.mhtml")
}

function New-MhtmlSaveResult {
    param(
        [string]$OriginalUrl,
        [string]$FinalUrl,
        [string]$Title,
        [string]$FilePath,
        [bool]$Saved,
        [int]$ChildCount,
        [string]$ParentUrl,
        [string]$SourceXml
    )

    return [pscustomobject]@{
        OriginalUrl = $OriginalUrl
        FinalUrl = $FinalUrl
        Title = $Title
        FilePath = $FilePath
        Saved = $Saved
        ChildCount = $ChildCount
        ParentUrl = $ParentUrl
        SourceXml = $SourceXml
    }
}

function Assert-PageLoadOk {
    param(
        $Data,
        $Task = $null
    )

    $title = [string]$Data.title
    $h1 = [string]$Data.h1
    $htmlLength = if ($Data.PSObject.Properties['htmlLength']) { [int]$Data.htmlLength } else { 0 }
    $isLearningSource = $Task -and (Test-LearningXmlSource -SourceXml ([string]$Task.SourceXml))
    $hasLearningContentMeta = $isLearningSource -and ($Data.PSObject.Properties.Name -contains 'hasContentMeta') -and [bool]$Data.hasContentMeta

    if (-not [string]::IsNullOrWhiteSpace($script:MainDocumentFailedText)) {
        if (Test-IgnorableNavigationFailure -ErrorText $script:MainDocumentFailedText) {
            $script:MainDocumentFailedText = ''
        }
        else {
            throw "Network error: $($script:MainDocumentFailedText)"
        }
    }

    if ($null -ne $script:MainDocumentStatus -and $script:MainDocumentStatus -ge 400) {
        $statusText = if ($script:MainDocumentStatusText) { " $($script:MainDocumentStatusText)" } else { '' }
        if ($hasLearningContentMeta) {
            Write-Host "HTTP $($script:MainDocumentStatus)$statusText diabaikan karena Learn detail sudah memuat div.content-item-header-meta."
            $script:MainDocumentStatus = $null
            $script:MainDocumentStatusText = ''
        }
        else {
            throw "HTTP $($script:MainDocumentStatus)$statusText"
        }
    }

    $hotToastErrors = @()
    if ($Data.PSObject.Properties['hotToastErrors']) {
        $hotToastErrors = @($Data.hotToastErrors | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }

    if ($hotToastErrors.Count -gt 0) {
        throw "Halaman menampilkan hot-toast error: $($hotToastErrors -join ' | ')"
    }

    if ($h1 -eq 'One more step' -and $htmlLength -lt 102400) {
        throw "Halaman terlihat error challenge: h1='$h1', size=$htmlLength bytes"
    }

    if (-not $hasLearningContentMeta -and "$title $h1" -match '(?i)\b(404|502|503|504|not found|bad gateway|service unavailable|gateway timeout|ERR_[A-Z_]+|DNS|refused|unreachable|can''t be reached)\b') {
        throw "Halaman terlihat error: title='$title', h1='$h1'"
    }
}

function Assert-FinalUrlDoesNotPointToKnownDifferentPage {
    param(
        $Task,
        $Data
    )

    if (-not $Task -or -not $Data) {
        return
    }

    $originalUrl = [string]$Task.Url
    $finalUrl = [string]$Data.href
    if ([string]::IsNullOrWhiteSpace($originalUrl) -or [string]::IsNullOrWhiteSpace($finalUrl)) {
        return
    }

    try {
        $originalKey = Get-CanonicalUrlKey $originalUrl
        $finalKey = Get-CanonicalUrlKey $finalUrl
        if ($finalKey -eq $originalKey) {
            return
        }

        if (Test-VersionDocumentationRootUrl -PageUrl $finalUrl) {
            throw "Final URL menuju root dokumentasi versi: task '$originalUrl' selesai di '$finalUrl'"
        }

        $knownUrlMap = Get-KnownUrlMapForSourceXml -SourceXml ([string]$Task.SourceXml)
        if ($knownUrlMap.ContainsKey($finalKey)) {
            throw "Final URL salah: task '$originalUrl' selesai di URL lain yang ada di list '$finalUrl'"
        }
    }
    catch {
        if ($_.Exception.Message -like 'Final URL salah:*' -or $_.Exception.Message -like 'Final URL menuju root dokumentasi versi:*') {
            throw
        }
    }
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
        if ($invalidChars.Contains($code) -or $code -lt 32 -or $char -eq ';') {
            [void]$builder.Append("&#$code`_")
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

function Test-LearningXmlSource {
    param([string]$SourceXml)

    if ([string]::IsNullOrWhiteSpace($SourceXml)) {
        return $false
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($SourceXml)
    return $baseName -in @('LearnMH', 'LearnUE', 'LearnFN')
}

function Get-IndexedSegment {
    param(
        [int]$Index,
        [string]$Title,
        [string]$SourceXml = ''
    )

    if (Test-LearningXmlSource -SourceXml $SourceXml) {
        return (ConvertTo-SafeSegment -Value $Title -MaxLength 100)
    }

    return ('{0}. {1}' -f $Index, (ConvertTo-SafeSegment -Value $Title -MaxLength 100))
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

function Test-ExcludedXmlLinkUrl {
    param(
        [string]$PageUrl,
        [string]$SourceXml = ''
    )

    if ([string]::IsNullOrWhiteSpace($PageUrl)) {
        return $false
    }

    try {
        $uri = [Uri]$PageUrl
        $urlHost = $uri.Host.ToLowerInvariant()
        $path = $uri.AbsolutePath.TrimEnd('/').ToLowerInvariant()
        $segments = @($path.Split('/') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        return (
            ($urlHost -eq 'fab.com' -or $urlHost.EndsWith('.fab.com')) -or
            ($urlHost -eq 'docs.unrealengine.com' -and (Test-LearningXmlSource -SourceXml $SourceXml)) -or
            (($urlHost -eq 'unrealengine.com' -or $urlHost.EndsWith('.unrealengine.com')) -and ($segments -contains 'marketplace'))
        )
    }
    catch {
        return $false
    }
}

function Test-PdfUrl {
    param([string]$PageUrl)

    if ([string]::IsNullOrWhiteSpace($PageUrl)) {
        return $false
    }

    try {
        $uri = [Uri]$PageUrl
        return $uri.AbsolutePath -match '(?i)\.pdf$'
    }
    catch {
        return ([string]$PageUrl) -match '(?i)\.pdf(?:[?#].*)?$'
    }
}

function Test-PdfFileValid {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $header = New-Object byte[] 5
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $read = $stream.Read($header, 0, $header.Length)
        }
        finally {
            $stream.Dispose()
        }

        return ($read -eq 5 -and [System.Text.Encoding]::ASCII.GetString($header) -eq '%PDF-')
    }
    catch {
        return $false
    }
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

function ConvertTo-TsvValue {
    param([string]$Value)

    return ([string]$Value -replace "`t", ' ' -replace "\r?\n", ' ').Trim()
}

function Get-IndexPathForXml {
    param(
        [string]$SourceXml,
        [ValidateSet('link', 'list')]
        [string]$Kind
    )

    $xmlPath = [System.IO.Path]::GetFullPath($SourceXml)
    $folder = [System.IO.Path]::GetDirectoryName($xmlPath)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($xmlPath)
    return (Join-Path $folder "$baseName-$Kind.tsv")
}

function Add-UrlToMap {
    param(
        [hashtable]$Map,
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return
    }

    try {
        $Map[(Get-CanonicalUrlKey $Url)] = $true
    }
    catch {
    }
}

function Add-TsvUrlsToMap {
    param(
        [hashtable]$Map,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return
    }

    try {
        $rows = @(Import-Csv -LiteralPath $Path -Delimiter "`t")
    }
    catch {
        Write-Warning "Tidak bisa membaca URL index: $Path - $($_.Exception.Message)"
        return
    }

    foreach ($row in $rows) {
        Add-UrlToMap -Map $Map -Url ([string]$row.url)
    }
}

function Get-KnownUrlMapForSourceXml {
    param([string]$SourceXml)

    if ([string]::IsNullOrWhiteSpace($SourceXml)) {
        return @{}
    }

    $xmlPath = [System.IO.Path]::GetFullPath($SourceXml)
    $cacheKey = $xmlPath.ToLowerInvariant()
    if ($script:KnownUrlMapCache.ContainsKey($cacheKey)) {
        return $script:KnownUrlMapCache[$cacheKey]
    }

    $map = @{}
    Add-TsvUrlsToMap -Map $map -Path (Get-IndexPathForXml -SourceXml $xmlPath -Kind 'link')
    Add-TsvUrlsToMap -Map $map -Path (Get-IndexPathForXml -SourceXml $xmlPath -Kind 'list')
    $script:KnownUrlMapCache[$cacheKey] = $map
    return $map
}

function Update-ListBackup {
    param([string]$ListPath)

    if ([string]::IsNullOrWhiteSpace($ListPath) -or -not (Test-Path -LiteralPath $ListPath)) {
        return
    }

    $backupPath = [System.IO.Path]::ChangeExtension($ListPath, '.bak')
    Copy-Item -LiteralPath $ListPath -Destination $backupPath -Force
}

function Ensure-ListFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path) -or (Get-Item -LiteralPath $Path).Length -eq 0) {
        Set-Content -LiteralPath $Path -Value "url`tfile`ttitle`tchild_count`tparent_url`tsource_xml`tsaved" -Encoding UTF8
        Update-ListBackup -ListPath $Path
    }
}

function Get-DownloadedResumeMap {
    param([string[]]$Paths)

    $urlMap = @{}
    $fileMap = @{}

    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
            continue
        }

        try {
            $rows = @(Import-Csv -LiteralPath $path -Delimiter "`t")
        }
        catch {
            Write-Warning "Tidak bisa membaca list resume: $path - $($_.Exception.Message)"
            continue
        }

        foreach ($row in $rows) {
            $rowUrl = [string]$row.url
            $rowFile = [string]$row.file
            $isPdfRow = Test-PdfUrl -PageUrl $rowUrl
            $rowFilePath = ''
            if (-not [string]::IsNullOrWhiteSpace($rowFile)) {
                try {
                    $rowFilePath = ConvertTo-LocalPathFromListValue $rowFile
                }
                catch {
                    $rowFilePath = $rowFile
                }
            }

            if ($isPdfRow -and (-not (Test-PdfFileValid -Path $rowFilePath))) {
                Write-Warning "PDF resume invalid, akan download ulang: $rowFile"
                continue
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$row.url)) {
                try {
                    $urlMap[(Get-CanonicalUrlKey $rowUrl)] = $true
                }
                catch {
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($rowFile)) {
                try {
                    $fileMap[$rowFilePath.ToLowerInvariant()] = $true
                }
                catch {
                    $fileMap[$rowFile.ToLowerInvariant()] = $true
                }
            }
        }
    }

    return [pscustomobject]@{
        UrlMap = $urlMap
        FileMap = $fileMap
        Count = $urlMap.Count
    }
}

function Get-ElementChildren {
    param(
        [System.Xml.XmlNode]$Node,
        [string]$LocalName = ''
    )

    $children = New-Object System.Collections.ArrayList
    foreach ($child in $Node.ChildNodes) {
        if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) {
            continue
        }
        if ($LocalName -and $child.LocalName -ne $LocalName) {
            continue
        }
        [void]$children.Add($child)
    }

    return @($children)
}

function ConvertTo-LocalPathFromListValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $path = ([string]$Value).Trim().Trim([char]34) -replace '/', '\'
    if ([System.IO.Path]::IsPathRooted($path)) {
        return [System.IO.Path]::GetFullPath($path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $path))
}

function Get-LinkIndexTasks {
    param(
        [string]$LinkPath,
        [string]$SourceXml
    )

    $tasks = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $LinkPath) -or (Get-Item -LiteralPath $LinkPath).Length -eq 0) {
        return @($tasks)
    }

    try {
        $rows = @(Import-Csv -LiteralPath $LinkPath -Delimiter "`t")
    }
    catch {
        Write-Warning "Tidak bisa membaca link existing: $LinkPath - $($_.Exception.Message)"
        return @($tasks)
    }

    foreach ($row in $rows) {
        if ([string]::IsNullOrWhiteSpace([string]$row.url) -or [string]::IsNullOrWhiteSpace([string]$row.file)) {
            continue
        }
        if (Test-ExcludedXmlLinkUrl -PageUrl ([string]$row.url) -SourceXml $SourceXml) {
            continue
        }

        $filePath = ConvertTo-LocalPathFromListValue ([string]$row.file)
        if (Test-PdfUrl -PageUrl ([string]$row.url)) {
            $filePath = [System.IO.Path]::ChangeExtension($filePath, '.pdf')
        }
        $saveFolder = ConvertTo-LocalPathFromListValue ([string]$row.save_folder)
        if ([string]::IsNullOrWhiteSpace($saveFolder)) {
            $saveFolder = [System.IO.Path]::GetDirectoryName($filePath)
        }

        $sourceXmlValue = if ([string]::IsNullOrWhiteSpace([string]$row.source_xml)) { $SourceXml } else { ConvertTo-LocalPathFromListValue ([string]$row.source_xml) }
        $childCount = 0
        [void][int]::TryParse([string]$row.child_count, [ref]$childCount)

        [void]$tasks.Add([pscustomobject]@{
            Url = [string]$row.url
            SaveFolder = $saveFolder
            FileBaseName = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
            FilePath = $filePath
            Title = [string]$row.title
            ParentUrl = [string]$row.parent_url
            SourceXml = $sourceXmlValue
            ChildCount = $childCount
        })
    }

    return @($tasks)
}

function Get-NextElementSibling {
    param([System.Xml.XmlNode]$Node)

    $next = $Node.NextSibling
    while ($next -and $next.NodeType -ne [System.Xml.XmlNodeType]::Element) {
        $next = $next.NextSibling
    }

    return $next
}

function Get-FirstAnchor {
    param([System.Xml.XmlElement]$Element)

    return $Element.SelectSingleNode('.//*[local-name()="a" and @href]')
}

function Get-NormalizedText {
    param([string]$Value)

    return ([System.Net.WebUtility]::HtmlDecode([string]$Value) -replace '\s+', ' ').Trim()
}

function Add-NavDivTask {
    param(
        [System.Xml.XmlElement]$Div,
        [string]$ParentFolder,
        [int]$Index,
        [string]$ParentUrl,
        [string]$SourceXml,
        [System.Collections.ArrayList]$Tasks
    )

    $anchor = Get-FirstAnchor -Element $Div
    if (-not $anchor) {
        return $false
    }

    $href = [string]$anchor.GetAttribute('href')
    $url = Resolve-PageUrl -BaseUrl 'https://dev.epicgames.com/' -Value $href
    if ([string]::IsNullOrWhiteSpace($url)) {
        return $false
    }
    if (Test-ExcludedXmlLinkUrl -PageUrl $url -SourceXml $SourceXml) {
        return $false
    }

    $title = Get-NormalizedText ([string]$anchor.InnerText)
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = $url
    }

    $segment = Get-IndexedSegment -Index $Index -Title $title -SourceXml $SourceXml
    $nodeFolder = [System.IO.Path]::GetFullPath((Join-Path $ParentFolder $segment))
    $fileExtension = if (Test-PdfUrl -PageUrl $url) { '.pdf' } else { '.mhtml' }
    $filePath = Join-Path $ParentFolder "$segment$fileExtension"

    $task = [pscustomobject]@{
        Url = $url
        SaveFolder = [System.IO.Path]::GetFullPath($ParentFolder)
        FileBaseName = $segment
        FilePath = $filePath
        Title = $title
        ParentUrl = $ParentUrl
        SourceXml = $SourceXml
        ChildCount = 0
    }
    [void]$Tasks.Add($task)

    $next = Get-NextElementSibling -Node $Div
    if (-not $next -or $next.LocalName -ne 'ul') {
        return $true
    }

    $childIndex = 0
    foreach ($li in (Get-ElementChildren -Node $next -LocalName 'li')) {
        $childDiv = $null
        foreach ($element in (Get-ElementChildren -Node $li)) {
            if ($element.LocalName -eq 'div') {
                $childDiv = $element
                break
            }
        }

        if (-not $childDiv) {
            continue
        }

        $childIndex++
        if (-not (Add-NavDivTask -Div $childDiv -ParentFolder $nodeFolder -Index $childIndex -ParentUrl $url -SourceXml $SourceXml -Tasks $Tasks)) {
            $childIndex--
        }
    }

    $task.ChildCount = $childIndex
    return $true
}

function Get-XmlDownloadTasks {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        throw "Folder mhtml tidak ditemukan: $Root"
    }

    $tasks = New-Object System.Collections.ArrayList
    $directXmlFiles = @(Get-ChildItem -LiteralPath $Root -File -Filter '*.xml')
    $xmlNameMap = @{}
    foreach ($file in $directXmlFiles) {
        $xmlNameMap[$file.Name.ToLowerInvariant()] = $true
    }

    $xmlFiles = @($directXmlFiles | Where-Object {
        $name = $_.Name.ToLowerInvariant()
        -not (
            ($name -eq 'learnue-list.xml' -and $xmlNameMap.ContainsKey('learnue.xml')) -or
            ($name -eq 'learnmh-list.xml' -and $xmlNameMap.ContainsKey('learnmh.xml')) -or
            ($name -eq 'learnfn-list.xml' -and $xmlNameMap.ContainsKey('learnfn.xml'))
        )
    } | Sort-Object Name)
    Write-Host "XML langsung di folder mhtml: $($xmlFiles.Count) file"

    foreach ($xmlFile in $xmlFiles) {
        $xmlFullName = [System.IO.Path]::GetFullPath($xmlFile.FullName)
        if ($script:XmlSourceFilesForLinkIndex -notcontains $xmlFullName) {
            $script:XmlSourceFilesForLinkIndex += @($xmlFullName)
        }

        $linkPath = Get-IndexPathForXml -SourceXml $xmlFile.FullName -Kind 'link'
        $existingTasks = @(Get-LinkIndexTasks -LinkPath $linkPath -SourceXml $xmlFile.FullName)
        if ($existingTasks.Count -gt 0) {
            foreach ($task in $existingTasks) {
                [void]$tasks.Add($task)
            }
            Write-Host "Pakai link existing: $(ConvertTo-RelativeRootPath $linkPath) -> $($existingTasks.Count) link"
            continue
        }

        $raw = Get-Content -LiteralPath $xmlFile.FullName -Raw
        [xml]$doc = '<root>' + $raw + '</root>'

        $outputRoot = Join-Path $xmlFile.DirectoryName $xmlFile.BaseName
        New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

        $rootIndex = 0
        foreach ($element in (Get-ElementChildren -Node $doc.DocumentElement)) {
            if ($element.LocalName -ne 'div') {
                continue
            }

            $rootIndex++
            if (-not (Add-NavDivTask -Div $element -ParentFolder $outputRoot -Index $rootIndex -ParentUrl '' -SourceXml $xmlFile.FullName -Tasks $tasks)) {
                $rootIndex--
            }
        }

        Write-Host "Baca XML: $(ConvertTo-RelativeRootPath $xmlFile.FullName) -> $rootIndex root"
    }

    return @($tasks)
}

function Write-LinkIndex {
    param($Tasks)

    $writtenPaths = New-Object System.Collections.ArrayList
    $sourceXmls = New-Object System.Collections.ArrayList
    foreach ($sourceXml in @($Tasks | Select-Object -ExpandProperty SourceXml -Unique) + @($script:XmlSourceFilesForLinkIndex)) {
        if ([string]::IsNullOrWhiteSpace([string]$sourceXml)) {
            continue
        }
        $fullSourceXml = [System.IO.Path]::GetFullPath([string]$sourceXml)
        if ($sourceXmls -notcontains $fullSourceXml) {
            [void]$sourceXmls.Add($fullSourceXml)
        }
    }

    foreach ($sourceXml in @($sourceXmls)) {
        $linkPath = Get-IndexPathForXml -SourceXml $sourceXml -Kind 'link'
        $groupTasks = @($Tasks | Where-Object {
            [System.IO.Path]::GetFullPath([string]$_.SourceXml) -ieq [string]$sourceXml
        })

        $rows = New-Object System.Collections.ArrayList
        [void]$rows.Add("url`tsave_folder`tfile`ttitle`tchild_count`tparent_url`tsource_xml")
        foreach ($task in @($groupTasks)) {
            if (Test-ExcludedXmlLinkUrl -PageUrl ([string]$task.Url) -SourceXml ([string]$task.SourceXml)) {
                continue
            }
            [void]$rows.Add((
                "$(ConvertTo-TsvValue $task.Url)`t" +
                "$(ConvertTo-TsvValue (ConvertTo-RelativeRootPath $task.SaveFolder))`t" +
                "$(ConvertTo-TsvValue (ConvertTo-RelativeRootPath $task.FilePath))`t" +
                "$(ConvertTo-TsvValue $task.Title)`t" +
                "$(ConvertTo-TsvValue ([string]$task.ChildCount))`t" +
                "$(ConvertTo-TsvValue $task.ParentUrl)`t" +
                "$(ConvertTo-TsvValue (ConvertTo-RelativeRootPath $task.SourceXml))"
            ))
        }

        Set-Content -LiteralPath $linkPath -Value ([string[]]$rows.ToArray()) -Encoding UTF8
        [void]$writtenPaths.Add($linkPath)
    }

    return @($writtenPaths)
}

function New-MhtmlPageSession {
    $target = Open-DevToolsUrl -OpenUrl 'about:blank'
    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

    [void](Invoke-CdpCommand -Socket $socket -Method 'Page.enable')
    [void](Invoke-CdpCommand -Socket $socket -Method 'Runtime.enable')
    [void](Invoke-CdpCommand -Socket $socket -Method 'Network.enable')
    if (-not $LoadImages) {
        [void](Invoke-CdpCommand -Socket $socket -Method 'Page.addScriptToEvaluateOnNewDocument' -Params @{
            source = Get-MhtmlCaptureBlockerExpression
        })
        [void](Invoke-CdpCommand -Socket $socket -Method 'Fetch.enable' -Params @{
            patterns = @(
                @{
                    urlPattern = '*'
                    resourceType = 'Image'
                    requestStage = 'Request'
                },
                @{
                    urlPattern = '*'
                    resourceType = 'Media'
                    requestStage = 'Request'
                }
            )
        })
    }
    return [pscustomobject]@{
        Socket = $socket
        TargetId = [string]$target.id
    }
}

function Close-MhtmlPageSession {
    param($Session)

    if (-not $Session) {
        return
    }

    try {
        if ($Session.Socket) {
            $Session.Socket.Dispose()
        }
    }
    catch {
    }

    Close-DevToolsPage -TargetId ([string]$Session.TargetId)
}

function Save-PdfFromBrowserSession {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        $Task
    )

    $pageUrl = [string]$Task.Url
    $filePath = [System.IO.Path]::GetFullPath([string]$Task.FilePath)
    $filePath = [System.IO.Path]::ChangeExtension($filePath, '.pdf')

    $folder = [System.IO.Path]::GetDirectoryName($filePath)
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $downloadDir = Join-Path $folder (".pdf-download-$PID-{0}" -f ([Guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

    Write-Host ""
    Write-Host "Buka Edge PDF: $pageUrl"

    try {
        [void](Invoke-CdpCommand -Socket $Socket -Method 'Page.setDownloadBehavior' -Params @{
            behavior = 'allow'
            downloadPath = $downloadDir
        })

        Reset-NetworkState
        $navigateResponse = Invoke-CdpCommand -Socket $Socket -Method 'Page.navigate' -Params @{ url = $pageUrl }
        Update-NetworkStateFromNavigateResult -Response $navigateResponse

        $deadline = (Get-Date).AddSeconds($PageLoadTimeoutSeconds)
        $downloadedPath = ''
        while ((Get-Date) -lt $deadline) {
            $partialFiles = @(Get-ChildItem -LiteralPath $downloadDir -File -Force -ErrorAction SilentlyContinue | Where-Object {
                    $_.Name -match '\.(crdownload|tmp)$'
                })
            $completeFiles = @(Get-ChildItem -LiteralPath $downloadDir -File -Force -ErrorAction SilentlyContinue | Where-Object {
                    $_.Name -notmatch '\.(crdownload|tmp)$'
                } | Sort-Object LastWriteTime -Descending)

            if ($completeFiles.Count -gt 0 -and $partialFiles.Count -eq 0) {
                $candidate = $completeFiles[0].FullName
                $sizeBefore = (Get-Item -LiteralPath $candidate).Length
                Start-Sleep -Milliseconds 500
                $sizeAfter = (Get-Item -LiteralPath $candidate).Length
                if ($sizeBefore -eq $sizeAfter -and $sizeAfter -gt 0) {
                    $downloadedPath = $candidate
                    break
                }
            }

            try {
                [void](Invoke-CdpCommand -Socket $Socket -Method 'Runtime.evaluate' -Params @{ expression = 'location.href'; returnByValue = $true })
            }
            catch {
            }
            Start-Sleep -Milliseconds 500
        }

        if ([string]::IsNullOrWhiteSpace($downloadedPath)) {
            throw "Timeout menunggu browser download PDF."
        }

        $header = New-Object byte[] 5
        $stream = [System.IO.File]::OpenRead($downloadedPath)
        try {
            $read = $stream.Read($header, 0, $header.Length)
        }
        finally {
            $stream.Dispose()
        }

        $headerText = [System.Text.Encoding]::ASCII.GetString($header)
        if ($read -lt 5 -or $headerText -ne '%PDF-') {
            throw "Hasil download bukan PDF valid: header='$headerText'"
        }

        Move-Item -LiteralPath $downloadedPath -Destination $filePath -Force

        $bytes = (Get-Item -LiteralPath $filePath).Length
        Write-Host "Simpan PDF: $(ConvertTo-RelativeRootPath $filePath) ($bytes bytes)"
        return (New-MhtmlSaveResult `
            -OriginalUrl $pageUrl `
            -FinalUrl $pageUrl `
            -Title ([string]$Task.Title) `
            -FilePath $filePath `
            -Saved $true `
            -ChildCount ([int]$Task.ChildCount) `
            -ParentUrl ([string]$Task.ParentUrl) `
            -SourceXml ([string]$Task.SourceXml))
    }
    finally {
        Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Save-MhtmlPageInSession {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        $Task
    )

    $pageUrl = [string]$Task.Url
    if (Test-PdfUrl -PageUrl $pageUrl) {
        return @(Save-PdfFromBrowserSession -Socket $Socket -Task $Task)
    }

    $baseFilePath = [System.IO.Path]::GetFullPath([string]$Task.FilePath)
    $saved = $false
    $data = $null
    $results = New-Object System.Collections.ArrayList
    $pageUrlCandidates = @(Get-PageUrlCandidates -PageUrl $pageUrl)
    $candidateIndex = 0
    $attempt = 0
    $lastErrorMessage = ''

    Write-Host ""
    Write-Host "Buka Edge: $pageUrl"
    while ($attempt -lt $MaxLoadAttempts -and $candidateIndex -lt $pageUrlCandidates.Count) {
        $attempt++
        $currentPageUrl = [string]$pageUrlCandidates[$candidateIndex]
        Reset-NetworkState
        if ($attempt -gt 1) {
            Write-Warning "Navigasi ulang ke URL error: $currentPageUrl"
        }

        if ($currentPageUrl -ne $pageUrl) {
            Write-Host "Coba versi dokumentasi: $currentPageUrl"
        }

        $navigateResponse = Invoke-CdpCommand -Socket $Socket -Method 'Page.navigate' -Params @{ url = $currentPageUrl }
        Update-NetworkStateFromNavigateResult -Response $navigateResponse

        try {
            $data = Wait-MhtmlPageReady -Socket $Socket -PageUrl $currentPageUrl -Attempt $attempt
            Assert-PageLoadOk -Data $data -Task $Task
            Assert-FinalUrlDoesNotPointToKnownDifferentPage -Task $Task -Data $data

            $switchJson = Invoke-PageEval -Socket $Socket -Expression (Get-MhtmlSwitchDiscoveryExpression) -AwaitPromise
            $switchData = $switchJson | ConvertFrom-Json
            $switchGroups = @()
            if ($switchData -and $switchData.groups) {
                $switchGroups = @($switchData.groups)
            }
            $switchCombinations = @(Get-SwitchOptionCombinations -Groups $switchGroups)
            if ($switchCombinations.Count -gt 1 -or ($switchCombinations.Count -eq 1 -and @($switchCombinations[0].Options).Count -gt 0)) {
                Write-Host "Variasi block-switch-control: $($switchCombinations.Count) kombinasi"
            }

            $title = if ($data -and -not [string]::IsNullOrWhiteSpace([string]$data.h1)) { [string]$data.h1 } else { [string]$Task.Title }
            $finalUrl = if ($data -and -not [string]::IsNullOrWhiteSpace([string]$data.href)) { [string]$data.href } else { $pageUrl }

            foreach ($combination in $switchCombinations) {
                $options = if ($combination.PSObject.Properties['Options']) {
                    @($combination.Options | ForEach-Object { [string]$_ })
                }
                else {
                    @($combination | ForEach-Object { [string]$_ })
                }
                if ($options.Count -gt 0) {
                    $selectJson = Invoke-PageEval -Socket $Socket -Expression (Get-MhtmlSwitchSelectExpression -Options $options) -AwaitPromise
                    $selectData = $selectJson | ConvertFrom-Json
                    $failedSelections = @($selectData.selected | Where-Object { -not $_.selected })
                    if ($failedSelections.Count -gt 0) {
                        Write-Warning "Sebagian opsi switch tidak bisa dipilih: $((@($failedSelections | ForEach-Object { $_.label }) -join ', '))"
                    }
                }

                $snippetJson = Invoke-PageEval -Socket $Socket -Expression (Get-MhtmlSnippetPrepareExpression -Parallelism $BlockCodeParallelism) -AwaitPromise
                $snippetData = $snippetJson | ConvertFrom-Json
                if ($snippetData -and [int]$snippetData.snippetCount -gt 0) {
                    $filledCount = @($snippetData.results | Where-Object { $_.filled }).Count
                    $injectedCount = @($snippetData.results | Where-Object { $_.injected }).Count
                    $typeSummary = @($snippetData.results | Group-Object type | ForEach-Object { "$($_.Name): $($_.Count)" }) -join ', '
                    $lineCountChecked = @($snippetData.results | Where-Object { $_.expectedLineCount -gt 0 })
                    $lineCountMatched = @($lineCountChecked | Where-Object { $_.lineCountOk }).Count
                    $lineCountMismatch = @($lineCountChecked | Where-Object { -not $_.lineCountOk })
                    $lineSummary = if ($lineCountChecked.Count -gt 0) { "; line sesuai tombol: $lineCountMatched/$($lineCountChecked.Count)" } else { '' }
                    Write-Host "Snippet source textarea terisi: $filledCount/$($snippetData.snippetCount); source tertanam: $injectedCount/$($snippetData.snippetCount) ($typeSummary)$lineSummary"
                    if ($lineCountMismatch.Count -gt 0) {
                        $mismatchSummary = @($lineCountMismatch | Group-Object type | ForEach-Object { "$($_.Name): $($_.Count)" }) -join ', '
                        Write-Warning "Snippet source jumlah baris tidak sesuai tombol Copy full snippet: $($lineCountMismatch.Count) ($mismatchSummary)"
                        $mismatchDetails = @($lineCountMismatch | Select-Object -First 5 | ForEach-Object {
                                $expandText = if ($_.PSObject.Properties['expandAttempted'] -and $_.expandAttempted) { " expand=$($_.expandOk) '$($_.expandLabel)'" } else { " expand=not-found" }
                                "#$($_.index) $($_.type) expected=$($_.expectedLineCount) actual=$($_.sourceLineCount)${expandText}: $($_.buttonLabel)"
                            }) -join ' | '
                        if (-not [string]::IsNullOrWhiteSpace($mismatchDetails)) {
                            Write-Warning "Detail snippet line mismatch: $mismatchDetails"
                        }
                        throw "Snippet source jumlah baris tidak sesuai tombol Copy full snippet: $($lineCountMismatch.Count) ($mismatchSummary)"
                    }
                }

                $filePath = Get-MhtmlVariantFilePath -BaseFilePath $baseFilePath -Options $options
                $folder = [System.IO.Path]::GetDirectoryName($filePath)
                New-Item -ItemType Directory -Force -Path $folder | Out-Null

                if (-not $LoadImages) {
                    [void](Invoke-PageEval -Socket $Socket -Expression (Get-MhtmlCaptureBlockerExpression))
                }
                $snapshot = Invoke-CdpCommand -Socket $Socket -Method 'Page.captureSnapshot' -Params @{ format = 'mhtml' }
                $snapshotData = [string]$snapshot.result.data
                $snapshotBytes = [System.Text.Encoding]::UTF8.GetByteCount($snapshotData)
                if ($snapshotBytes -lt $MinimumMhtmlBytes) {
                    throw "MHTML terlalu kecil: $snapshotBytes bytes (< $MinimumMhtmlBytes bytes)"
                }

                [System.IO.File]::WriteAllText($filePath, $snapshotData, [System.Text.UTF8Encoding]::new($false))
                $saved = $true
                [void]$results.Add((New-MhtmlSaveResult `
                    -OriginalUrl $pageUrl `
                    -FinalUrl $finalUrl `
                    -Title $title `
                    -FilePath $filePath `
                    -Saved $true `
                    -ChildCount ([int]$Task.ChildCount) `
                    -ParentUrl ([string]$Task.ParentUrl) `
                    -SourceXml ([string]$Task.SourceXml)))
                Write-Host "Simpan MHTML: $(ConvertTo-RelativeRootPath $filePath) ($snapshotBytes bytes)"
            }
            break
        }
        catch {
            $lastErrorMessage = $_.Exception.Message
            if ($lastErrorMessage -like 'Final URL menuju root dokumentasi versi:*') {
                Write-Warning $lastErrorMessage
                $candidateIndex++
                if ($candidateIndex -lt $pageUrlCandidates.Count) {
                    Write-Warning "Coba fallback application_version berikutnya: $($pageUrlCandidates[$candidateIndex])"
                    continue
                }
            }

            if ($attempt -ge $MaxLoadAttempts -or $candidateIndex -ge $pageUrlCandidates.Count) {
                throw
            }
            Write-Warning $lastErrorMessage
        }
    }

    if (-not $saved) {
        if ([string]::IsNullOrWhiteSpace($lastErrorMessage)) {
            $lastErrorMessage = 'Tidak ada kandidat URL yang berhasil.'
        }
        throw "Gagal menyimpan MHTML: $pageUrl - $lastErrorMessage"
    }

    return @($results)
}

function Save-MhtmlPage {
    param($Task)

    $session = $null
    try {
        $session = New-MhtmlPageSession
        return Save-MhtmlPageInSession -Socket $session.Socket -Task $Task
    }
    finally {
        Close-MhtmlPageSession -Session $session
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

    $results = @($Result)
    $first = if ($results.Count -gt 0) { $results[0] } else { $null }

    return [pscustomobject]@{
        WorkerResult = $true
        WorkerId = $Id
        TaskId = $TaskId
        Success = $true
        OriginalUrl = if ($first) { $first.OriginalUrl } else { '' }
        FinalUrl = if ($first) { $first.FinalUrl } else { '' }
        Title = if ($first) { $first.Title } else { '' }
        FilePath = if ($first) { $first.FilePath } else { '' }
        RelativeFile = if ($first) { ConvertTo-RelativeRootPath $first.FilePath } else { '' }
        Saved = if ($first) { $first.Saved } else { $false }
        ChildCount = if ($first) { $first.ChildCount } else { 0 }
        ParentUrl = if ($first) { $first.ParentUrl } else { '' }
        SourceXml = if ($first) { $first.SourceXml } else { '' }
        Results = @($results | ForEach-Object {
            $item = $_
            [pscustomobject]@{
                OriginalUrl = $item.OriginalUrl
                FinalUrl = $item.FinalUrl
                Title = $item.Title
                FilePath = $item.FilePath
                RelativeFile = (ConvertTo-RelativeRootPath $item.FilePath)
                Saved = $item.Saved
                ChildCount = $item.ChildCount
                ParentUrl = $item.ParentUrl
                SourceXml = $item.SourceXml
            }
        })
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
        ChildCount = 0
        ParentUrl = ''
        SourceXml = ''
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
                    Close-MhtmlPageSession -Session $session
                    $session = New-MhtmlPageSession
                }

                $workerResult = Save-MhtmlPageInSession -Socket $session.Socket -Task $task
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
        Close-MhtmlPageSession -Session $session
    }
}

if ($WorkerMode) {
    if (-not [string]::IsNullOrWhiteSpace($WorkerIpcDir)) {
        Invoke-PersistentPageWorker -Id $WorkerId -Directory $WorkerIpcDir
        return
    }

    try {
        $workerTask = [pscustomobject]@{
            Url = $WorkerPageUrl
            SaveFolder = [System.IO.Path]::GetFullPath($WorkerSaveFolder)
            FileBaseName = ''
            FilePath = Join-Path ([System.IO.Path]::GetFullPath($WorkerSaveFolder)) 'page.mhtml'
            Title = ''
            ParentUrl = ''
            SourceXml = ''
            ChildCount = 0
        }
        $workerResult = Save-MhtmlPage -Task $workerTask
        New-WorkerSuccessResult -Id $WorkerId -TaskId 0 -Result $workerResult
    }
    catch {
        New-WorkerErrorResult -Id $WorkerId -TaskId 0 -PageUrl $WorkerPageUrl -ErrorMessage $_.Exception.Message
    }
    return
}

function Add-DownloadedResultToList {
    param(
        $Result,
        $ResumeMap
    )

    if (-not $Result -or [string]::IsNullOrWhiteSpace([string]$Result.FilePath)) {
        return
    }

    $cleanOriginalUrl = Remove-UrlApplicationVersion ([string]$Result.OriginalUrl)
    $urlKey = ''
    if (-not [string]::IsNullOrWhiteSpace($cleanOriginalUrl)) {
        try {
            $urlKey = Get-CanonicalUrlKey $cleanOriginalUrl
        }
        catch {
        }
    }

    $fileKey = ''
    try {
        $fileKey = ([System.IO.Path]::GetFullPath([string]$Result.FilePath)).ToLowerInvariant()
    }
    catch {
        $fileKey = ([string]$Result.FilePath).ToLowerInvariant()
    }

    if ($ResumeMap.PSObject.Properties['FileMap'] -and $fileKey -and $ResumeMap.FileMap.ContainsKey($fileKey)) {
        return
    }

    $listPath = Get-IndexPathForXml -SourceXml $Result.SourceXml -Kind 'list'
    Ensure-ListFile -Path $listPath
    Add-Content -LiteralPath $listPath -Value (
        "$(ConvertTo-TsvValue $cleanOriginalUrl)`t" +
        "$(ConvertTo-TsvValue $Result.RelativeFile)`t" +
        "$(ConvertTo-TsvValue $Result.Title)`t" +
        "$(ConvertTo-TsvValue ([string]$Result.ChildCount))`t" +
        "$(ConvertTo-TsvValue $Result.ParentUrl)`t" +
        "$(ConvertTo-TsvValue (ConvertTo-RelativeRootPath $Result.SourceXml))`t" +
        "$(ConvertTo-TsvValue ([string]$Result.Saved))"
    ) -Encoding UTF8
    Update-ListBackup -ListPath $listPath
    if ($urlKey) {
        $ResumeMap.UrlMap[$urlKey] = $true
    }
    if ($ResumeMap.PSObject.Properties['FileMap'] -and $fileKey) {
        $ResumeMap.FileMap[$fileKey] = $true
    }
    $ResumeMap.Count = $ResumeMap.UrlMap.Count
}

function Import-LocalDownloadedFiles {
    param(
        [object[]]$Tasks,
        $ResumeMap
    )

    $imported = 0
    foreach ($task in @($Tasks)) {
        if (-not $task -or [string]::IsNullOrWhiteSpace([string]$task.Url) -or [string]::IsNullOrWhiteSpace([string]$task.FilePath)) {
            continue
        }

        $urlKey = ''
        try {
            $urlKey = Get-CanonicalUrlKey ([string]$task.Url)
        }
        catch {
        }

        if ($urlKey -and $ResumeMap.UrlMap.ContainsKey($urlKey)) {
            continue
        }

        $filePath = [System.IO.Path]::GetFullPath([string]$task.FilePath)
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            continue
        }
        if ((Test-PdfUrl -PageUrl ([string]$task.Url)) -and (-not (Test-PdfFileValid -Path $filePath))) {
            Write-Warning "PDF lokal invalid, tidak diadopsi ke list: $(ConvertTo-RelativeRootPath $filePath)"
            continue
        }

        $relativeFile = ConvertTo-RelativeRootPath $filePath
        $result = [pscustomobject]@{
            OriginalUrl = [string]$task.Url
            FinalUrl = [string]$task.Url
            Title = [string]$task.Title
            FilePath = $filePath
            RelativeFile = $relativeFile
            Saved = $true
            ChildCount = [int]$task.ChildCount
            ParentUrl = [string]$task.ParentUrl
            SourceXml = [string]$task.SourceXml
        }

        Add-DownloadedResultToList -Result $result -ResumeMap $ResumeMap
        $imported++
    }

    if ($imported -gt 0) {
        Write-Host "Adopsi file MHTML lokal ke list: $imported file"
    }
}

function Get-NextTask {
    param(
        [System.Collections.ArrayList]$Queue,
        [hashtable]$SeenFiles
    )

    while ($Queue.Count -gt 0) {
        $task = $Queue[$Queue.Count - 1]
        $Queue.RemoveAt($Queue.Count - 1)

        $key = [System.IO.Path]::GetFullPath([string]$task.FilePath).ToLowerInvariant()
        if ($SeenFiles.ContainsKey($key)) {
            continue
        }
        $SeenFiles[$key] = $true
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
        [hashtable]$SeenFiles,
        $Task,
        [string]$ErrorMessage
    )

    $key = [System.IO.Path]::GetFullPath([string]$Task.FilePath).ToLowerInvariant()
    if ($SeenFiles.ContainsKey($key)) {
        $SeenFiles.Remove($key)
    }

    $retryCount = 1
    if ($Task.PSObject.Properties['RetryCount']) {
        $retryCount = [int]$Task.RetryCount + 1
    }

    Write-Warning "Job gagal, masuk antrean ulang #${retryCount}: $($Task.Url) - $ErrorMessage"
    [void]$Queue.Add([pscustomobject]@{
        Url = [string]$Task.Url
        SaveFolder = [string]$Task.SaveFolder
        FileBaseName = [string]$Task.FileBaseName
        FilePath = [string]$Task.FilePath
        Title = [string]$Task.Title
        ParentUrl = [string]$Task.ParentUrl
        SourceXml = [string]$Task.SourceXml
        ChildCount = [int]$Task.ChildCount
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
            [double]$PageIdleSeconds,
            [int]$PageLoadTimeoutSeconds,
            [int]$MaxLoadAttempts,
            [int]$BlockCodeParallelism,
            [bool]$OverwriteFlag,
            [bool]$LoadImagesFlag,
            [string]$MhtmlRoot
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
            -BlockCodeParallelism $BlockCodeParallelism `
            -Overwrite:$OverwriteFlag `
            -LoadImages:$LoadImagesFlag `
            -MhtmlRoot $MhtmlRoot
    } -ArgumentList @(
        $scriptPath,
        $script:BrowserPort,
        $Id,
        $IpcDir,
        $BrowserPollSeconds,
        $PageIdleSeconds,
        $PageLoadTimeoutSeconds,
        $MaxLoadAttempts,
        $BlockCodeParallelism,
        $Overwrite.IsPresent,
        $LoadImages.IsPresent,
        $MhtmlRoot
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
        FileBaseName = [string]$Task.FileBaseName
        FilePath = [string]$Task.FilePath
        Title = [string]$Task.Title
        ParentUrl = [string]$Task.ParentUrl
        SourceXml = [string]$Task.SourceXml
        ChildCount = [int]$Task.ChildCount
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
        [hashtable]$SeenFiles,
        $ResumeMap
    )

    while ($Queue.Count -gt 0 -and (Test-CanStartMore -StartedCount $started)) {
        $task = Get-NextTask -Queue $Queue -SeenFiles $SeenFiles
        if (-not $task) {
            return $null
        }

        if (Test-ExcludedXmlLinkUrl -PageUrl ([string]$task.Url) -SourceXml ([string]$task.SourceXml)) {
            Write-Host "Lewati link eksternal marketplace/Fab: $($task.Url)"
            continue
        }

        $urlKey = ''
        try {
            $urlKey = Get-CanonicalUrlKey ([string]$task.Url)
        }
        catch {
        }

        if ($urlKey -and $ResumeMap.UrlMap.ContainsKey($urlKey)) {
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

$allTasks = @(Get-XmlDownloadTasks -Root $MhtmlRoot)
$linkPaths = @(Write-LinkIndex -Tasks $allTasks)
$listPaths = @($allTasks | Select-Object -ExpandProperty SourceXml -Unique | ForEach-Object {
    $listPath = Get-IndexPathForXml -SourceXml $_ -Kind 'list'
    Ensure-ListFile -Path $listPath
    $listPath
})

foreach ($linkPath in $linkPaths) {
    Write-Host "Index link dari XML: $linkPath"
}
Write-Host "Total link dari XML: $($allTasks.Count)"

$seenFiles = @{}
$downloadedResumeMap = Get-DownloadedResumeMap -Paths $listPaths
$downloaded = 0
$started = 0

if ($downloadedResumeMap.Count -gt 0) {
    Write-Host "Index resume URL terbaca: $($downloadedResumeMap.Count) URL dari $($listPaths.Count) list"
}

if ($DryRun) {
    Write-Host "DryRun aktif: tidak ada halaman yang didownload."
    if (-not $NoPause) {
        pause
    }
    return
}

Import-LocalDownloadedFiles -Tasks $allTasks -ResumeMap $downloadedResumeMap

$stack = New-Object System.Collections.ArrayList
for ($taskIndex = $allTasks.Count - 1; $taskIndex -ge 0; $taskIndex--) {
    [void]$stack.Add($allTasks[$taskIndex])
}

if ($ParallelPages -le 1) {
    while ($stack.Count -gt 0) {
        if (-not (Test-CanStartMore -StartedCount $started)) {
            Write-Host "MaxPages tercapai: $MaxPages"
            break
        }

        $task = Get-NextBrowserTask -Queue $stack -SeenFiles $seenFiles -ResumeMap $downloadedResumeMap
        if (-not $task) {
            break
        }

        $started++
        try {
            $results = @(Save-MhtmlPage -Task $task)
            foreach ($result in $results) {
                $result | Add-Member -NotePropertyName RelativeFile -NotePropertyValue (ConvertTo-RelativeRootPath $result.FilePath) -Force
                $downloaded++
                Add-DownloadedResultToList -Result $result -ResumeMap $downloadedResumeMap
            }
        }
        catch {
            if ($started -gt 0) {
                $started--
            }
            Add-FailedTaskBack -Queue $stack -SeenFiles $seenFiles -Task $task -ErrorMessage $_.Exception.Message
        }
    }
}
else {
    Ensure-Edge
    Write-Host "ParallelPages aktif: $ParallelPages"

    $workerIpcDir = Join-Path $MhtmlRoot (".mhtml-workers-$PID-{0}" -f (Get-Date -Format 'yyyyMMddHHmmss'))
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
                        $workerResults = if ($result.PSObject.Properties['Results'] -and $result.Results) { @($result.Results) } else { @($result) }
                        foreach ($workerResult in $workerResults) {
                            $downloaded++
                            Add-DownloadedResultToList -Result $workerResult -ResumeMap $downloadedResumeMap

                            Write-Host "Simpan: $($workerResult.RelativeFile)"
                        }
                    }
                    else {
                        if ($started -gt 0) {
                            $started--
                        }
                        Add-FailedTaskBack -Queue $stack -SeenFiles $seenFiles -Task $worker.Task -ErrorMessage $result.Error
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
                    Add-FailedTaskBack -Queue $stack -SeenFiles $seenFiles -Task $worker.Task -ErrorMessage "worker #$($worker.Id) berhenti sebelum mengembalikan hasil"

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

                $task = Get-NextBrowserTask -Queue $stack -SeenFiles $seenFiles -ResumeMap $downloadedResumeMap
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
foreach ($linkPath in $linkPaths) {
    Write-Host "Daftar link XML: $linkPath"
}
foreach ($listPath in $listPaths) {
    Write-Host "Daftar hasil: $listPath"
}

if (-not $NoPause) {
    pause
}
