param(
    [string]$MhtmlRoot = (Join-Path $PSScriptRoot 'mhtml'),
    [int]$BrowserPollSeconds = 1,
    [double]$PageIdleSeconds = 0.1,
    [int]$PageLoadTimeoutSeconds = 3000,
    [int]$MaxLoadAttempts = 100000,
    [int]$ParallelPages = 5,
    [int]$MaxPages = 0,
    [switch]$DryRun,
    [switch]$NoPause,
    [switch]$WorkerMode,
    [int]$WorkerBrowserPort = 0,
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
$MhtmlRoot = [System.IO.Path]::GetFullPath($MhtmlRoot)

$script:BrowserPort = if ($WorkerMode) { $WorkerBrowserPort } else { $null }
$script:BrowserProfileDir = Join-Path $MhtmlRoot '.edge-profile'
$script:CdpCommandId = 0
$script:MainDocumentStatus = $null
$script:MainDocumentStatusText = ''
$script:MainDocumentFailedText = ''
$script:MainDocumentRequestId = ''
$script:StartedEdgeProfileDirs = New-Object System.Collections.ArrayList

$Targets = @(
    [pscustomobject]@{
        Key = 'LearnUE'
        Title = 'Unreal Engine Learning'
        RootUrl = 'https://dev.epicgames.com/community/unreal-engine/learning'
        OutputPath = (Join-Path $MhtmlRoot 'LearnUE.xml')
    },
    [pscustomobject]@{
        Key = 'LearnMH'
        Title = 'MetaHuman Learning'
        RootUrl = 'https://dev.epicgames.com/community/metahuman/learning'
        OutputPath = (Join-Path $MhtmlRoot 'LearnMH.xml')
    }
)

if ($WorkerMode) {
    if ($WorkerBrowserPort -le 0) {
        throw 'WorkerBrowserPort wajib diisi untuk WorkerMode.'
    }
    if ([string]::IsNullOrWhiteSpace($WorkerIpcDir)) {
        throw 'WorkerIpcDir wajib diisi untuk WorkerMode.'
    }
    if ($WorkerId -le 0) {
        throw 'WorkerId wajib diisi untuk WorkerMode.'
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

        Start-Process -FilePath $edgePath -ArgumentList $arguments -WindowStyle Hidden | Out-Null
        [void]$script:StartedEdgeProfileDirs.Add($profileDir)

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

function Stop-StartedEdge {
    foreach ($profileDir in @($script:StartedEdgeProfileDirs)) {
        if ([string]::IsNullOrWhiteSpace($profileDir)) {
            continue
        }

        $needle = [regex]::Escape([System.IO.Path]::GetFullPath($profileDir))
        try {
            Get-CimInstance Win32_Process -Filter "name = 'msedge.exe'" | Where-Object {
                $_.CommandLine -match $needle
            } | ForEach-Object {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
        }
    }
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

function Get-LearningSnapshotExpression {
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
  const pageNumberFromHref = (href) => {
    const text = href || '';
    const match = text.match(/(?:\/page\/|[?&]page=)(\d+)/i);
    return match ? Number(match[1]) : 0;
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

  const pagination = document.querySelector('pagination') || document.querySelector('[class*="pagination" i]');
  const pageNumbers = [1];
  if (pagination) {
    pagination.querySelectorAll('a[href], button, [aria-label]').forEach((el) => {
      const label = normalize(el.getAttribute('aria-label') || el.textContent || '');
      const href = el.getAttribute('href') || '';
      const labelMatch = label.match(/\b(\d+)\b/g);
      if (labelMatch) labelMatch.forEach((value) => pageNumbers.push(Number(value)));
      const fromHref = pageNumberFromHref(href);
      if (fromHref) pageNumbers.push(fromHref);
    });
  }

  const learningList = document.querySelector('learning-list') || document.querySelector('[class*="learning-list" i]');
  const linkScope = learningList || document;
  const seen = new Set();
  const items = [];
  linkScope.querySelectorAll('a[href]').forEach((anchor) => {
    const url = toUrl(anchor.getAttribute('href'));
    if (!url || seen.has(url)) return;
    const parsed = new URL(url);
    if (parsed.hostname !== location.hostname) return;
    if (!/\/community\//i.test(parsed.pathname)) return;
    if (/\/learning(?:\/page\/\d+)?\/?$/i.test(parsed.pathname)) return;

    const titleEl = anchor.querySelector('h1,h2,h3,h4,[class*="title" i],[class*="heading" i]');
    const title = normalize(anchor.getAttribute('aria-label') || anchor.getAttribute('title') || titleEl?.textContent || anchor.textContent || url);
    if (!title) return;

    seen.add(url);
    items.push({ title, url });
  });

  const h1 = document.querySelector('h1');
  const htmlLength = document.documentElement?.outerHTML?.length || 0;

  return JSON.stringify({
    href: location.href,
    readyState: document.readyState,
    title: document.title || '',
    h1: normalize(h1?.textContent || ''),
    totalPages: Math.max(...pageNumbers.filter(Number.isFinite), 1),
    hasPagination: !!pagination,
    hasLearningList: !!learningList,
    itemCount: items.length,
    items,
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

function Wait-LearningPageReady {
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

        $json = Invoke-PageEval -Socket $Socket -Expression (Get-LearningSnapshotExpression)
        $data = $json | ConvertFrom-Json
        $lastData = $data

        $hasPageData = $data.hasLearningList -or $data.itemCount -gt 0 -or $data.hasPagination
        if (-not $data.isLoading -and $hasPageData) {
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
    $count = if ($lastData) { [int]$lastData.itemCount } else { 0 }
    throw "Timeout load halaman attempt #${Attempt}: $PageUrl title='$title' h1='$h1' item_count=$count"
}

function Assert-PageLoadOk {
    param($Data)

    if (-not [string]::IsNullOrWhiteSpace($script:MainDocumentFailedText) -and $script:MainDocumentFailedText -ne 'net::ERR_ABORTED') {
        throw "Network error: $($script:MainDocumentFailedText)"
    }

    if ($null -ne $script:MainDocumentStatus -and $script:MainDocumentStatus -ge 400) {
        $statusText = if ($script:MainDocumentStatusText) { " $($script:MainDocumentStatusText)" } else { '' }
        throw "HTTP $($script:MainDocumentStatus)$statusText"
    }

    $title = [string]$Data.title
    $h1 = [string]$Data.h1
    if ("$title $h1" -match '(?i)\b(404|502|503|504|not found|bad gateway|service unavailable|gateway timeout|ERR_[A-Z_]+|DNS|refused|unreachable|timed out|can''t be reached)\b') {
        throw "Halaman terlihat error: title='$title', h1='$h1'"
    }
}

function ConvertTo-PageUrl {
    param(
        [string]$RootUrl,
        [int]$Page
    )

    return "$($RootUrl.TrimEnd('/'))/page/$Page"
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

function ConvertTo-XmlAttributeValue {
    param([string]$Value)

    return [System.Security.SecurityElement]::Escape([string]$Value)
}

function ConvertTo-SafeText {
    param([string]$Value)

    return (([string]$Value) -replace '\s+', ' ').Trim()
}

function New-LearningPageSession {
    $target = Open-DevToolsUrl -OpenUrl 'about:blank'
    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

    [void](Invoke-CdpCommand -Socket $socket -Method 'Page.enable')
    [void](Invoke-CdpCommand -Socket $socket -Method 'Runtime.enable')
    [void](Invoke-CdpCommand -Socket $socket -Method 'Network.enable')

    return [pscustomobject]@{
        Socket = $socket
        TargetId = [string]$target.id
    }
}

function Close-LearningPageSession {
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

function Get-LearningPageDataInSession {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [string]$PageUrl
    )

    Write-Host "Buka Edge: $PageUrl"
    for ($attempt = 1; $attempt -le $MaxLoadAttempts; $attempt++) {
        Reset-NetworkState
        if ($attempt -gt 1) {
            Write-Warning "Navigasi ulang ke URL error: $PageUrl"
        }

        $navigateResponse = Invoke-CdpCommand -Socket $Socket -Method 'Page.navigate' -Params @{ url = $PageUrl }
        Update-NetworkStateFromNavigateResult -Response $navigateResponse

        try {
            $data = Wait-LearningPageReady -Socket $Socket -PageUrl $PageUrl -Attempt $attempt
            Assert-PageLoadOk -Data $data
            return [pscustomobject]@{
                PageUrl = $PageUrl
                FinalUrl = [string]$data.href
                Title = [string]$data.h1
                TotalPages = [int]$data.totalPages
                Items = @($data.items)
            }
        }
        catch {
            if ($attempt -ge $MaxLoadAttempts) {
                throw
            }
            Write-Warning $_.Exception.Message
        }
    }

    throw "Gagal membaca halaman: $PageUrl"
}

function Get-LearningPageData {
    param([string]$PageUrl)

    $session = $null
    try {
        $session = New-LearningPageSession
        return Get-LearningPageDataInSession -Socket $session.Socket -PageUrl $PageUrl
    }
    finally {
        Close-LearningPageSession -Session $session
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
        Page = $Result.Page
        TargetKey = $Result.TargetKey
        PageUrl = $Result.PageUrl
        FinalUrl = $Result.FinalUrl
        TotalPages = $Result.TotalPages
        Items = @($Result.Items)
        Error = ''
    }
}

function New-WorkerErrorResult {
    param(
        [int]$Id,
        [int]$TaskId,
        [int]$Page,
        [string]$TargetKey,
        [string]$PageUrl,
        [string]$ErrorMessage
    )

    return [pscustomobject]@{
        WorkerResult = $true
        WorkerId = $Id
        TaskId = $TaskId
        Success = $false
        Page = $Page
        TargetKey = $TargetKey
        PageUrl = $PageUrl
        FinalUrl = ''
        TotalPages = 0
        Items = @()
        Error = $ErrorMessage
    }
}

function Invoke-PersistentLearningWorker {
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
        $session = New-LearningPageSession
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
            $page = 0
            $targetKey = ''
            try {
                $task = Get-Content -LiteralPath $currentTaskPath -Raw | ConvertFrom-Json
                $taskId = [int]$task.TaskId
                $pageUrl = [string]$task.Url
                $page = [int]$task.Page
                $targetKey = [string]$task.TargetKey

                if (-not $session -or $session.Socket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
                    Close-LearningPageSession -Session $session
                    $session = New-LearningPageSession
                }

                $pageResult = Get-LearningPageDataInSession -Socket $session.Socket -PageUrl $pageUrl
                $pageResult | Add-Member -NotePropertyName Page -NotePropertyValue $page -Force
                $pageResult | Add-Member -NotePropertyName TargetKey -NotePropertyValue $targetKey -Force
                $result = New-WorkerSuccessResult -Id $Id -TaskId $taskId -Result $pageResult
            }
            catch {
                $result = New-WorkerErrorResult -Id $Id -TaskId $taskId -Page $page -TargetKey $targetKey -PageUrl $pageUrl -ErrorMessage $_.Exception.Message
            }

            $tempResultPath = "$resultPath.tmp"
            $result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $tempResultPath -Encoding UTF8
            Move-Item -LiteralPath $tempResultPath -Destination $resultPath -Force
            Remove-Item -LiteralPath $currentTaskPath -Force -ErrorAction SilentlyContinue
        }
    }
    finally {
        Close-LearningPageSession -Session $session
    }
}

if ($WorkerMode) {
    Invoke-PersistentLearningWorker -Id $WorkerId -Directory $WorkerIpcDir
    return
}

function Start-LearningWorkerJob {
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
        $MhtmlRoot
    )
}

function Receive-WorkerOutput {
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
        TargetKey = [string]$Task.TargetKey
        Page = [int]$Task.Page
        Url = [string]$Task.Url
    }

    $tempPath = "$($Worker.TaskPath).tmp"
    $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $Worker.TaskPath -Force

    $Worker.Busy = $true
    $Worker.Task = $Task
    $Worker.TaskId = $TaskId
    Write-Host "Worker #$($Worker.Id) proses page $($Task.Page): $($Task.Url)"
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

function Stop-LearningWorkers {
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
            Receive-WorkerOutput -Worker $worker
            Remove-Job -Job $worker.Job -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($IpcDir) -and (Test-Path -LiteralPath $IpcDir)) {
        Remove-Item -LiteralPath $IpcDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-LearningXml {
    param(
        $Target,
        [object[]]$Items
    )

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add(('<div class="contents-table-el is-active is-root-entry"><a class="contents-table-link is-parent" href="{0}">{1}</a></div>' -f (ConvertTo-XmlAttributeValue $Target.RootUrl), (ConvertTo-XmlAttributeValue $Target.Title)))
    [void]$lines.Add('<ul class="contents-table-list">')

    $seen = @{}
    foreach ($item in @($Items)) {
        if (-not $item -or [string]::IsNullOrWhiteSpace([string]$item.url)) {
            continue
        }

        $key = Get-CanonicalUrlKey ([string]$item.url)
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true

        $title = ConvertTo-SafeText ([string]$item.title)
        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = [string]$item.url
        }

        $href = ConvertTo-XmlAttributeValue ([string]$item.url)
        $label = ConvertTo-XmlAttributeValue $title
        [void]$lines.Add("`t<li class=""contents-table-item"">")
        [void]$lines.Add(('`t`t<div class="contents-table-el"><a class="contents-table-link" href="{0}">{1}</a></div>' -f $href, $label))
        [void]$lines.Add("`t</li>")
    }

    [void]$lines.Add('</ul>')
    return [string[]]$lines.ToArray()
}

function Invoke-ParallelPageReads {
    param([object[]]$Tasks)

    $results = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.ArrayList
    foreach ($task in @($Tasks)) {
        [void]$queue.Add($task)
    }

    if ($ParallelPages -le 1) {
        while ($queue.Count -gt 0) {
            $task = $queue[0]
            $queue.RemoveAt(0)
            $result = Get-LearningPageData -PageUrl ([string]$task.Url)
            $result | Add-Member -NotePropertyName Page -NotePropertyValue ([int]$task.Page) -Force
            $result | Add-Member -NotePropertyName TargetKey -NotePropertyValue ([string]$task.TargetKey) -Force
            [void]$results.Add($result)
        }
        return @($results)
    }

    Ensure-Edge
    Write-Host "ParallelPages aktif: $ParallelPages"

    $workerIpcDir = Join-Path $MhtmlRoot (".xml-workers-$PID-{0}" -f (Get-Date -Format 'yyyyMMddHHmmss'))
    New-Item -ItemType Directory -Force -Path $workerIpcDir | Out-Null

    $workers = New-Object System.Collections.ArrayList
    for ($workerId = 1; $workerId -le $ParallelPages; $workerId++) {
        $job = Start-LearningWorkerJob -Id $workerId -IpcDir $workerIpcDir
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
        while ($queue.Count -gt 0 -or @($workers | Where-Object { $_.Busy }).Count -gt 0) {
            $madeProgress = $false

            foreach ($worker in @($workers)) {
                Receive-WorkerOutput -Worker $worker
                $result = Receive-WorkerResult -Worker $worker
                if ($result) {
                    if ($result.Success) {
                        [void]$results.Add($result)
                        Write-Host "Selesai page $($result.Page): $($result.PageUrl) ($(@($result.Items).Count) link)"
                    }
                    else {
                        throw "Worker #$($worker.Id) gagal page $($worker.Task.Page): $($result.Error)"
                    }

                    $worker.Busy = $false
                    $worker.Task = $null
                    $worker.TaskId = 0
                    $madeProgress = $true
                }
                elseif ($worker.Busy -and $worker.Job.State -ne 'Running') {
                    throw "Worker #$($worker.Id) berhenti sebelum mengembalikan hasil"
                }
                elseif (-not $worker.Busy -and $worker.Job.State -ne 'Running') {
                    Clear-WorkerPendingFiles -Worker $worker
                    Remove-Job -Job $worker.Job -Force -ErrorAction SilentlyContinue
                    $worker.Job = Start-LearningWorkerJob -Id $worker.Id -IpcDir $workerIpcDir
                    $madeProgress = $true
                }
            }

            foreach ($worker in @($workers | Where-Object { -not $_.Busy })) {
                if ($queue.Count -eq 0) {
                    break
                }

                $task = $queue[0]
                $queue.RemoveAt(0)
                $nextTaskId++
                Send-TaskToWorker -Worker $worker -Task $task -TaskId $nextTaskId
                $madeProgress = $true
            }

            if (-not $madeProgress) {
                Start-Sleep -Milliseconds 250
            }
        }
    }
    finally {
        Stop-LearningWorkers -Workers $workers -IpcDir $workerIpcDir
    }

    return @($results)
}

$allPageTasks = New-Object System.Collections.ArrayList
foreach ($target in $Targets) {
    Write-Host ""
    Write-Host "Baca root: $($target.RootUrl)"
    $rootData = Get-LearningPageData -PageUrl $target.RootUrl
    $totalPages = [Math]::Max(1, [int]$rootData.TotalPages)
    if ($MaxPages -gt 0) {
        $totalPages = [Math]::Min($totalPages, $MaxPages)
    }

    $target | Add-Member -NotePropertyName TotalPages -NotePropertyValue $totalPages -Force
    Write-Host "Total page $($target.Key): $totalPages"

    for ($page = 1; $page -le $totalPages; $page++) {
        [void]$allPageTasks.Add([pscustomobject]@{
            TargetKey = [string]$target.Key
            Page = $page
            Url = (ConvertTo-PageUrl -RootUrl $target.RootUrl -Page $page)
        })
    }
}

if ($DryRun) {
    Write-Host "DryRun aktif: tidak menulis XML."
    foreach ($target in $Targets) {
        Write-Host "$($target.Key): $($target.TotalPages) page -> $($target.OutputPath)"
    }
    Stop-StartedEdge
    if (-not $NoPause) {
        pause
    }
    return
}

$pageResults = @(Invoke-ParallelPageReads -Tasks @($allPageTasks))
foreach ($target in $Targets) {
    $targetResults = @($pageResults | Where-Object { [string]$_.TargetKey -eq [string]$target.Key } | Sort-Object Page)
    $items = New-Object System.Collections.ArrayList
    foreach ($result in $targetResults) {
        foreach ($item in @($result.Items)) {
            [void]$items.Add($item)
        }
    }

    $xmlLines = ConvertTo-LearningXml -Target $target -Items @($items)
    Set-Content -LiteralPath $target.OutputPath -Value $xmlLines -Encoding UTF8
    Write-Host "Tulis XML: $(ConvertTo-RelativeRootPath $target.OutputPath) ($(@($items).Count) link mentah)"
}

Write-Host ""
Write-Host "Selesai generate XML learning."
Stop-StartedEdge
if (-not $NoPause) {
    pause
}
