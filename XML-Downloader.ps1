param(
    [string]$MhtmlRoot = (Join-Path $PSScriptRoot 'mhtml'),
    [int]$BrowserPollSeconds = 1,
    [double]$PageIdleSeconds = 0.1,
    [int]$PageLoadTimeoutSeconds = 30,
    [int]$MaxLoadAttempts = 100000,
    [int]$ParallelPages = 6,
    [int]$MaxPages = 0,
    [switch]$Doc,
    [switch]$Learn,
    [string]$Custom = '',
    [switch]$LoadImages,
    [switch]$DryRun,
    [switch]$NoPause,
    [switch]$WorkerMode,
    [ValidateSet('Page', 'Detail')]
    [string]$WorkerTaskKind = 'Page',
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

$LearningTargets = @(
    [pscustomobject]@{
        Key = 'LearnUE'
        Title = 'Unreal Engine Learning'
        RootUrl = 'https://dev.epicgames.com/community/unreal-engine/learning'
        OutputPath = (Join-Path $MhtmlRoot 'LearnUE.xml')
        ListOutputPath = (Join-Path $MhtmlRoot 'LearnUE-list.xml')
    },
    [pscustomobject]@{
        Key = 'LearnMH'
        Title = 'MetaHuman Learning'
        RootUrl = 'https://dev.epicgames.com/community/metahuman/learning'
        OutputPath = (Join-Path $MhtmlRoot 'LearnMH.xml')
        ListOutputPath = (Join-Path $MhtmlRoot 'LearnMH-list.xml')
    },
    [pscustomobject]@{
        Key = 'LearnFN'
        Title = 'Fortnite Learning'
        RootUrl = 'https://dev.epicgames.com/community/fortnite/learning'
        OutputPath = (Join-Path $MhtmlRoot 'LearnFN.xml')
        ListOutputPath = (Join-Path $MhtmlRoot 'LearnFN-list.xml')
    }
)

$DocumentationTargets = @(
    [pscustomobject]@{
        Key = 'UnrealEngine'
        Title = 'Unreal Engine Documentation'
        RootUrl = 'https://dev.epicgames.com/documentation/unreal-engine'
        OutputPath = (Join-Path $MhtmlRoot 'UnrealEngine.xml')
    },
    [pscustomobject]@{
        Key = 'MetaHuman'
        Title = 'MetaHuman Documentation'
        RootUrl = 'https://dev.epicgames.com/documentation/metahuman'
        OutputPath = (Join-Path $MhtmlRoot 'MetaHuman.xml')
    },
    [pscustomobject]@{
        Key = 'Fab'
        Title = 'Fab Documentation'
        RootUrl = 'https://dev.epicgames.com/documentation/fab'
        OutputPath = (Join-Path $MhtmlRoot 'Fab.xml')
    },
    [pscustomobject]@{
        Key = 'Fortnite'
        Title = 'Fortnite Documentation'
        RootUrl = 'https://dev.epicgames.com/documentation/fortnite'
        OutputPath = (Join-Path $MhtmlRoot 'Fortnite.xml')
    }
)

$BuildCustom = -not [string]::IsNullOrWhiteSpace($Custom)
$BuildAll = -not $Doc -and -not $Learn -and -not $BuildCustom
$BuildDoc = $BuildAll -or $Doc
$BuildLearn = $BuildAll -or $Learn

if ($BuildCustom) {
    $customKey = $Custom.Trim()
    $allTargets = @($LearningTargets) + @($DocumentationTargets)
    $matchedTargets = @($allTargets | Where-Object { [string]$_.Key -ieq $customKey })

    if ($matchedTargets.Count -ne 1) {
        $availableKeys = @($allTargets | ForEach-Object { [string]$_.Key }) -join ', '
        throw "Custom Key tidak ditemukan: '$Custom'. Pilihan: $availableKeys"
    }

    $selectedTarget = $matchedTargets[0]
    $LearningTargets = @($LearningTargets | Where-Object { [string]$_.Key -eq [string]$selectedTarget.Key })
    $DocumentationTargets = @($DocumentationTargets | Where-Object { [string]$_.Key -eq [string]$selectedTarget.Key })
    $BuildLearn = $LearningTargets.Count -gt 0
    $BuildDoc = $DocumentationTargets.Count -gt 0
}

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
        $isEmbedUrl = $requestUrl -match '(?i)(youtube\.com/embed|player\.vimeo\.com|embed|iframe)'
        $shouldBlock = -not $LoadImages -and (
            $resourceType -eq 'Image' -or
            $resourceType -eq 'Media' -or
            ($resourceType -eq 'Other' -and $isEmbedUrl) -or
            $requestUrl -match '(?i)/community/api/(learning|documentation|user_profiles)/image/' -or
            $requestUrl -match '(?i)[?&]resizing_type=' -or
            ($resourceType -ne 'Document' -and $isEmbedUrl)
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
  const toastErrors = Array.from(document.querySelectorAll('hot-toast-container hot-toast, hot-toast'))
    .map((toast) => normalize(toast.textContent || ''))
    .filter((text) => /\berror\b/i.test(text));

  const pagination = document.querySelector('pagination') || document.querySelector('[class*="pagination" i]');
  const pageNumbers = [1];
  if (pagination) {
    pagination.querySelectorAll('a[href], button, [aria-label]').forEach((el) => {
      const label = normalize(el.getAttribute('aria-label') || el.textContent || '');
      const lowerLabel = label.toLowerCase();
      if (/\b(next|previous|prev|first|last)\b/.test(lowerLabel)) return;

      const exactMatch = label.match(/^\s*(?:page\s*)?(\d+)\s*$/i);
      const pageLabelMatch = label.match(/\bpage\s+(\d+)\b/i);
      const value = exactMatch ? exactMatch[1] : (pageLabelMatch ? pageLabelMatch[1] : '');
      if (value) pageNumbers.push(Number(value));
    });
  }

  const learningList = document.querySelector('learning-list') || document.querySelector('[class*="learning-list" i]');
  const totalResultsText = normalize(document.querySelector('div.filter-options-container span')?.textContent || '');
  const totalResultsMatch = totalResultsText.match(/\b([\d,.]+)\s+results?\b/i) || totalResultsText.match(/\b([\d,.]+)\b/);
  const totalResults = totalResultsMatch ? Number(totalResultsMatch[1].replace(/[,.]/g, '')) : 0;
  const seen = new Set();
  const items = [];
  const listItems = learningList ? Array.from(learningList.querySelectorAll('li')) : [];
  listItems.forEach((li) => {
    const heading = li.querySelector('h6');
    const anchor = heading?.closest('a[href]') || heading?.parentElement?.closest('a[href]') || li.querySelector('a[href]');
    if (!anchor) return;

    const url = toUrl(anchor.getAttribute('href'));
    if (!url || seen.has(url)) return;
    const parsed = new URL(url);
    if (parsed.hostname !== location.hostname) return;
    if (!/\/community\//i.test(parsed.pathname)) return;
    if (/\/learning(?:\/page\/\d+)?\/?$/i.test(parsed.pathname)) return;

    const title = normalize(heading?.textContent || anchor.getAttribute('aria-label') || anchor.getAttribute('title') || anchor.textContent || url);
    if (!title) return;

    seen.add(url);
    items.push({ title, url, html: li.outerHTML || '' });
  });

  const h1 = document.querySelector('h1');
  const htmlLength = document.documentElement?.outerHTML?.length || 0;

  return JSON.stringify({
    href: location.href,
    readyState: document.readyState,
    title: document.title || '',
    h1: normalize(h1?.textContent || ''),
    totalPages: Math.max(...pageNumbers.filter(Number.isFinite), 1),
    totalResults,
    totalResultsText,
    hasPagination: !!pagination,
    hasLearningList: !!learningList,
    itemCount: items.length,
    items,
    toastErrorCount: toastErrors.length,
    toastErrors,
    loadingCount,
    isLoading: document.readyState !== 'complete' || loadingCount > 0,
    htmlLength
  });
})()
'@
}

function Get-DocumentationSnapshotExpression {
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
  const directChild = (el, selector) => Array.from(el?.children || []).find((child) => child.matches(selector)) || null;
  const isVisible = (el) => {
    const style = getComputedStyle(el);
    if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) return false;
    const rect = el.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  };
  const isExpandButton = (button) => {
    const label = normalize(button.getAttribute('aria-label') || button.getAttribute('title') || button.textContent || '');
    return /^expand\b/i.test(label) || /\bexpand\b/i.test(label);
  };
  const isCollapseButton = (button) => {
    const label = normalize(button.getAttribute('aria-label') || button.getAttribute('title') || button.textContent || '');
    return /^collapse\b/i.test(label) || /\bcollapse\b/i.test(label);
  };
  const cleanUrl = (href) => {
    const url = toUrl(href);
    if (!url) return '';
    try {
      const parsed = new URL(url);
      parsed.hash = '';
      return parsed.href;
    } catch (_) {
      return url;
    }
  };
  const readItem = (li) => {
    const row = directChild(li, '.contents-table-el') || li.querySelector(':scope > .contents-table-el, :scope > div');
    const anchor = row?.querySelector('a[href]') || li.querySelector(':scope > a[href]');
    const nested = directChild(li, 'ul') || li.querySelector(':scope > ul');
    const title = normalize(anchor?.textContent || row?.textContent || '');
    const url = cleanUrl(anchor?.getAttribute('href') || '');
    const children = nested ? readList(nested) : [];
    if (!title && !url && children.length === 0) return null;
    return { title: title || url, url, children };
  };
  const readList = (ul) => Array.from(ul?.children || [])
    .filter((child) => child.matches('li'))
    .map(readItem)
    .filter(Boolean);

  const toc = document.querySelector('table-of-contents');
  const contentsTable = toc?.querySelector('ul.contents-table') || null;
  const buttons = toc ? Array.from(toc.querySelectorAll('button.btn-expander, button[aria-label]')) : [];
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

  const h1 = document.querySelector('h1');
  const rootTitle = normalize(h1?.textContent || document.title || location.href);
  const items = contentsTable ? readList(contentsTable) : [];
  const expandButtonCount = buttons.filter(isExpandButton).length;
  const collapseButtonCount = buttons.filter(isCollapseButton).length;

  return JSON.stringify({
    href: location.href,
    readyState: document.readyState,
    title: document.title || '',
    h1: rootTitle,
    hasTableOfContents: !!toc,
    hasContentsTable: !!contentsTable,
    itemCount: items.length,
    expandButtonCount,
    collapseButtonCount,
    loadingCount,
    isLoading: document.readyState !== 'complete' || loadingCount > 0,
    items
  });
})()
'@
}

function Get-LearningDetailSnapshotExpression {
    return @'
(() => {
  const normalize = (value) => (value || '').replace(/\s+/g, ' ').trim();
  const toUrl = (value) => {
    if (!value) return '';
    try {
      const url = new URL(value, document.baseURI);
      if (!/^https?:$/i.test(url.protocol)) return '';
      url.hash = '';
      return url.href;
    } catch (_) {
      return '';
    }
  };
  const parseStepNumber = (value) => {
    const match = normalize(value).match(/\d+/);
    return match ? Number(match[0]) : Number.MAX_SAFE_INTEGER;
  };
  const getPublishedTime = () => {
    const meta = document.querySelector('div.content-item-header-meta');
    const times = meta ? Array.from(meta.querySelectorAll('time[datetime], time')) : [];
    const candidates = times.filter((time) => {
      const text = normalize(time.parentElement?.textContent || time.closest('li, div, span')?.textContent || '');
      return !/last\s+updated\s*:/i.test(text);
    });
    const time = candidates[0] || times[0] || null;
    const datetime = time ? (time.getAttribute('datetime') || time.dateTime || normalize(time.textContent || '')) : '';
    const timestamp = datetime ? Date.parse(datetime) : 0;
    return {
      publishedAt: datetime || '',
      publishedTimestamp: Number.isFinite(timestamp) ? timestamp : 0
    };
  };
  const uniqueChildren = (children) => {
    const seen = new Set();
    return children.filter((child) => {
      if (!child || !child.url || seen.has(child.url)) return false;
      seen.add(child.url);
      return true;
    });
  };
  const readCourseChildren = () => {
    const nav = document.querySelector('nav-course');
    const list = nav?.querySelector('ul.course-steps-list');
    if (!list) return [];
    const anchors = Array.from(list.querySelectorAll('li.course-steps-link a[href], li .course-steps-link a[href], a.course-steps-link[href], li a[href]'));
    return uniqueChildren(anchors.map((anchor, index) => ({
      title: normalize(anchor.textContent || anchor.getAttribute('aria-label') || anchor.getAttribute('title') || ''),
      url: toUrl(anchor.getAttribute('href')),
      order: index + 1
    }))).filter((child) => child.title && child.url);
  };
  const readLearningPathChildren = () => {
    if (!document.querySelector('h2.learning-path-title')) return [];
    const anchors = Array.from(document.querySelectorAll('a.list-item-link[href]'));
    return uniqueChildren(anchors.map((anchor, index) => {
      const stepNumber = parseStepNumber(anchor.querySelector('.list-item-step-number')?.textContent || '');
      const title = normalize(anchor.querySelector('.list-item-step-title')?.textContent || anchor.textContent || anchor.getAttribute('aria-label') || '');
      return {
        title,
        url: toUrl(anchor.getAttribute('href')),
        order: Number.isFinite(stepNumber) ? stepNumber : index + 1
      };
    }).sort((a, b) => a.order - b.order)).filter((child) => child.title && child.url);
  };

  const h1 = document.querySelector('h1');
  const published = getPublishedTime();
  const courseChildren = readCourseChildren();
  const pathChildren = readLearningPathChildren();
  const children = courseChildren.length > 0 ? courseChildren : pathChildren;

  return JSON.stringify({
    href: location.href,
    readyState: document.readyState,
    title: document.title || '',
    h1: normalize(h1?.textContent || ''),
    publishedAt: published.publishedAt,
    publishedTimestamp: published.publishedTimestamp,
    hasContentMeta: !!document.querySelector('div.content-item-header-meta'),
    hasCourseOutline: courseChildren.length > 0,
    hasLearningPath: !!document.querySelector('h2.learning-path-title'),
    children
  });
})()
'@
}

function Get-DocumentationExpandExpression {
    param([int]$MaxClicks = 500)

    return @"
(() => {
  const normalize = (value) => (value || '').replace(/\s+/g, ' ').trim();
  const isExpandButton = (button) => {
    const label = normalize(button.getAttribute('aria-label') || button.getAttribute('title') || button.textContent || '');
    return /^expand\b/i.test(label) || /\bexpand\b/i.test(label);
  };
  const toc = document.querySelector('table-of-contents');
  if (!toc) {
    return JSON.stringify({ clicked: 0, expandButtonCount: 0, hasTableOfContents: false, hasContentsTable: false });
  }

  const buttons = Array.from(toc.querySelectorAll('button.btn-expander, button[aria-label]')).filter(isExpandButton);
  let clicked = 0;
  for (const button of buttons.slice(0, $MaxClicks)) {
    try {
      button.scrollIntoView({ block: 'center', inline: 'nearest' });
      button.click();
      clicked++;
    } catch (_) {
    }
  }

  const remaining = Array.from(toc.querySelectorAll('button.btn-expander, button[aria-label]')).filter(isExpandButton).length;
  const contentsTable = toc.querySelector('ul.contents-table');
  return JSON.stringify({
    clicked,
    expandButtonCount: Math.max(remaining - clicked, 0),
    hasTableOfContents: true,
    hasContentsTable: !!contentsTable
  });
})()
"@
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

        if ([int]$data.toastErrorCount -gt 0) {
            $toastText = (@($data.toastErrors) -join '; ')
            throw "Toast error: $toastText"
        }

        $hasPageData = $data.itemCount -gt 0
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
    $hasContentItemHeaderMeta = $Data.PSObject.Properties.Name -contains 'hasContentMeta' -and [bool]$Data.hasContentMeta
    if (-not $hasContentItemHeaderMeta -and "$title $h1" -match '(?i)\b(404|502|503|504|not found|bad gateway|service unavailable|gateway timeout|ERR_[A-Z_]+|DNS|refused|unreachable|can''t be reached)\b') {
        throw "Halaman terlihat error: title='$title', h1='$h1'"
    }
}

function ConvertTo-PageUrl {
    param(
        [string]$RootUrl,
        [int]$Page
    )

    return "$($RootUrl.TrimEnd('/'))/page/$Page`?sort_by=first_published_at"
}

function ConvertTo-LearningRootUrl {
    param([string]$RootUrl)

    return "$($RootUrl.TrimEnd('/'))?sort_by=first_published_at"
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

function ConvertTo-LearningTargetTotal {
    param(
        [string]$TargetKey,
        [int]$TotalResults
    )

    if ($TotalResults -le 0) {
        return 0
    }

    if ([string]$TargetKey -ne 'LearnUE') {
        return $TotalResults
    }

    return [Math]::Max(0, $TotalResults - 1)
}

function New-LearningPageSession {
    $target = Open-DevToolsUrl -OpenUrl 'about:blank'
    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

    [void](Invoke-CdpCommand -Socket $socket -Method 'Page.enable')
    [void](Invoke-CdpCommand -Socket $socket -Method 'Runtime.enable')
    [void](Invoke-CdpCommand -Socket $socket -Method 'Network.enable')
    if (-not $LoadImages) {
        [void](Invoke-CdpCommand -Socket $socket -Method 'Page.addScriptToEvaluateOnNewDocument' -Params @{
            source = @'
(() => {
  const removeEmbeds = () => {
    document.querySelectorAll('iframe, embed, object, video, audio').forEach((el) => {
      try { el.remove(); } catch (_) {}
    });
  };
  removeEmbeds();
  new MutationObserver(removeEmbeds).observe(document.documentElement || document, { childList: true, subtree: true });
})();
'@
        })
    }
    if (-not $LoadImages) {
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
                },
                @{
                    urlPattern = '*'
                    resourceType = 'Other'
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
                TotalResults = [int]$data.totalResults
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

function Wait-LearningDetailPageReady {
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

        $json = Invoke-PageEval -Socket $Socket -Expression (Get-LearningDetailSnapshotExpression)
        $data = $json | ConvertFrom-Json
        $lastData = $data

        $hasPageData = -not [string]::IsNullOrWhiteSpace([string]$data.h1) -or
            $data.hasContentMeta -or
            @($data.children).Count -gt 0

        if ($data.readyState -eq 'complete' -and $hasPageData) {
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
    throw "Timeout load learning detail attempt #${Attempt}: $PageUrl title='$title' h1='$h1'"
}

function Get-LearningDetailDataInSession {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [string]$PageUrl
    )

    Write-Host "Buka detail learning: $PageUrl"
    for ($attempt = 1; $attempt -le $MaxLoadAttempts; $attempt++) {
        Reset-NetworkState
        if ($attempt -gt 1) {
            Write-Warning "Navigasi ulang ke URL detail learning error: $PageUrl"
        }

        $navigateResponse = Invoke-CdpCommand -Socket $Socket -Method 'Page.navigate' -Params @{ url = $PageUrl }
        Update-NetworkStateFromNavigateResult -Response $navigateResponse

        try {
            $data = Wait-LearningDetailPageReady -Socket $Socket -PageUrl $PageUrl -Attempt $attempt
            Assert-PageLoadOk -Data $data
            return [pscustomobject]@{
                PageUrl = $PageUrl
                FinalUrl = [string]$data.href
                Title = [string]$data.h1
                PublishedAt = [string]$data.publishedAt
                PublishedTimestamp = [double]$data.publishedTimestamp
                Children = @($data.children)
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            if ($attempt -ge $MaxLoadAttempts) {
                throw
            }
            Write-Warning "$errorMessage Reload detail learning: $PageUrl"
        }
    }

    throw "Gagal membaca halaman detail learning: $PageUrl"
}

function Invoke-SerialLearningDetailScan {
    param([object[]]$Items)

    $session = $null
    $enriched = New-Object System.Collections.ArrayList
    $seenFinalUrls = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    try {
        $session = New-LearningPageSession
        $index = 0
        foreach ($item in @($Items)) {
            $index++
            $originalUrl = [string]$item.url
            if ([string]::IsNullOrWhiteSpace($originalUrl)) {
                continue
            }

            Write-Host "Detail $index/$($Items.Count): $originalUrl"
            $detail = $null
            try {
                $detail = Get-LearningDetailDataInSession -Socket $session.Socket -PageUrl $originalUrl
            }
            catch {
                Write-Warning "Gagal detail: $originalUrl - $($_.Exception.Message)"
                continue
            }

            $finalUrl = if ($detail -and -not [string]::IsNullOrWhiteSpace([string]$detail.FinalUrl)) { [string]$detail.FinalUrl } else { $originalUrl }
            $key = Get-CanonicalUrlKey -PageUrl $finalUrl
            if ($seenFinalUrls.Contains($key)) {
                continue
            }
            [void]$seenFinalUrls.Add($key)

            $title = ConvertTo-SafeText ([string]$item.title)
            if ($detail -and -not [string]::IsNullOrWhiteSpace([string]$detail.Title)) {
                $title = ConvertTo-SafeText ([string]$detail.Title)
            }
            if ([string]::IsNullOrWhiteSpace($title)) {
                $title = $finalUrl
            }

            [void]$enriched.Add([pscustomobject]@{
                title = $title
                url = $finalUrl
                originalUrl = $originalUrl
                html = [string]$item.html
                publishedAt = if ($detail) { [string]$detail.PublishedAt } else { '' }
                publishedTimestamp = if ($detail) { [double]$detail.PublishedTimestamp } else { 0 }
                children = if ($detail) { @($detail.Children) } else { @() }
            })
        }
    }
    finally {
        Close-LearningPageSession -Session $session
    }

    return @($enriched | Sort-Object @{ Expression = { [double]$_.publishedTimestamp }; Descending = $true }, @{ Expression = { [string]$_.title }; Ascending = $true })
}

function Invoke-LearningDetailScan {
    param([object[]]$Items)

    if ($ParallelPages -le 1 -or @($Items).Count -le 1) {
        return @(Invoke-SerialLearningDetailScan -Items $Items)
    }

    return @(Invoke-ParallelLearningDetailReads -Items $Items)
}

function Wait-DocumentationPageReady {
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

        $expandJson = Invoke-PageEval -Socket $Socket -Expression (Get-DocumentationExpandExpression)
        $expandData = $expandJson | ConvertFrom-Json
        if ($expandData.clicked -gt 0) {
            $stableSince = $null
            Write-Host "  Expand TOC: klik $($expandData.clicked) tombol"
            continue
        }

        $json = Invoke-PageEval -Socket $Socket -Expression (Get-DocumentationSnapshotExpression)
        $data = $json | ConvertFrom-Json
        $lastData = $data

        $hasPageData = $data.hasTableOfContents -and $data.hasContentsTable -and $data.itemCount -gt 0
        if (-not $data.isLoading -and $hasPageData -and [int]$data.expandButtonCount -eq 0) {
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
    $expandCount = if ($lastData) { [int]$lastData.expandButtonCount } else { 0 }
    throw "Timeout load documentation attempt #${Attempt}: $PageUrl title='$title' h1='$h1' item_count=$count expand_count=$expandCount"
}

function Get-DocumentationPageDataInSession {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [string]$PageUrl
    )

    Write-Host "Buka Edge documentation: $PageUrl"
    for ($attempt = 1; $attempt -le $MaxLoadAttempts; $attempt++) {
        Reset-NetworkState
        if ($attempt -gt 1) {
            Write-Warning "Navigasi ulang ke URL documentation error: $PageUrl"
        }

        $navigateResponse = Invoke-CdpCommand -Socket $Socket -Method 'Page.navigate' -Params @{ url = $PageUrl }
        Update-NetworkStateFromNavigateResult -Response $navigateResponse

        try {
            $data = Wait-DocumentationPageReady -Socket $Socket -PageUrl $PageUrl -Attempt $attempt
            Assert-PageLoadOk -Data $data
            return [pscustomobject]@{
                PageUrl = $PageUrl
                FinalUrl = [string]$data.href
                Title = [string]$data.h1
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

    throw "Gagal membaca halaman documentation: $PageUrl"
}

function Get-DocumentationPageData {
    param([string]$PageUrl)

    $session = $null
    try {
        $session = New-LearningPageSession
        return Get-DocumentationPageDataInSession -Socket $session.Socket -PageUrl $PageUrl
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
        TotalResults = $Result.TotalResults
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
        TotalResults = 0
        Items = @()
        Error = $ErrorMessage
    }
}

function New-WorkerDetailSuccessResult {
    param(
        [int]$Id,
        [int]$TaskId,
        [int]$ItemIndex,
        [string]$OriginalUrl,
        [string]$FallbackTitle,
        [string]$Html,
        $Detail
    )

    $finalUrl = if ($Detail -and -not [string]::IsNullOrWhiteSpace([string]$Detail.FinalUrl)) { [string]$Detail.FinalUrl } else { $OriginalUrl }
    $title = ConvertTo-SafeText $FallbackTitle
    if ($Detail -and -not [string]::IsNullOrWhiteSpace([string]$Detail.Title)) {
        $title = ConvertTo-SafeText ([string]$Detail.Title)
    }
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = $finalUrl
    }

    return [pscustomobject]@{
        WorkerResult = $true
        WorkerId = $Id
        TaskId = $TaskId
        Success = $true
        ItemIndex = $ItemIndex
        title = $title
        url = $finalUrl
        originalUrl = $OriginalUrl
        html = $Html
        publishedAt = if ($Detail) { [string]$Detail.PublishedAt } else { '' }
        publishedTimestamp = if ($Detail) { [double]$Detail.PublishedTimestamp } else { 0 }
        children = if ($Detail) { @($Detail.Children) } else { @() }
        Error = ''
    }
}

function New-WorkerDetailErrorResult {
    param(
        [int]$Id,
        [int]$TaskId,
        [int]$ItemIndex,
        [string]$OriginalUrl,
        [string]$ErrorMessage
    )

    return [pscustomobject]@{
        WorkerResult = $true
        WorkerId = $Id
        TaskId = $TaskId
        Success = $false
        ItemIndex = $ItemIndex
        originalUrl = $OriginalUrl
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

function Invoke-PersistentLearningDetailWorker {
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
        Write-Host "Detail worker #$Id siap menunggu task."

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

            $taskId = 0
            $itemIndex = 0
            $pageUrl = ''
            try {
                $task = Get-Content -LiteralPath $currentTaskPath -Raw | ConvertFrom-Json
                $taskId = [int]$task.TaskId
                $itemIndex = [int]$task.ItemIndex
                $pageUrl = [string]$task.Url
                $fallbackTitle = [string]$task.Title
                $html = [string]$task.Html

                if (-not $session -or $session.Socket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
                    Close-LearningPageSession -Session $session
                    $session = New-LearningPageSession
                }

                $detail = Get-LearningDetailDataInSession -Socket $session.Socket -PageUrl $pageUrl
                $result = New-WorkerDetailSuccessResult -Id $Id -TaskId $taskId -ItemIndex $itemIndex -OriginalUrl $pageUrl -FallbackTitle $fallbackTitle -Html $html -Detail $detail
            }
            catch {
                $result = New-WorkerDetailErrorResult -Id $Id -TaskId $taskId -ItemIndex $itemIndex -OriginalUrl $pageUrl -ErrorMessage $_.Exception.Message
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
    if ($WorkerTaskKind -eq 'Detail') {
        Invoke-PersistentLearningDetailWorker -Id $WorkerId -Directory $WorkerIpcDir
    }
    else {
        Invoke-PersistentLearningWorker -Id $WorkerId -Directory $WorkerIpcDir
    }
    return
}

function Start-LearningWorkerJob {
    param(
        [int]$Id,
        [string]$IpcDir,
        [string]$TaskKind = 'Page'
    )

    Ensure-Edge
    Write-Host "Mulai $TaskKind worker #${Id}"

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
            [string]$TaskKind,
            [int]$BrowserPollSeconds,
            [double]$PageIdleSeconds,
            [int]$PageLoadTimeoutSeconds,
            [int]$MaxLoadAttempts,
            [string]$MhtmlRoot,
            [bool]$LoadImages
        )

        if ($LoadImages) {
            & $ScriptPath `
                -WorkerMode `
                -LoadImages `
                -WorkerTaskKind $TaskKind `
                -WorkerBrowserPort $BrowserPort `
                -WorkerId $Id `
                -WorkerIpcDir $IpcDir `
                -BrowserPollSeconds $BrowserPollSeconds `
                -PageIdleSeconds $PageIdleSeconds `
                -PageLoadTimeoutSeconds $PageLoadTimeoutSeconds `
                -MaxLoadAttempts $MaxLoadAttempts `
                -MhtmlRoot $MhtmlRoot
        }
        else {
            & $ScriptPath `
                -WorkerMode `
                -WorkerTaskKind $TaskKind `
                -WorkerBrowserPort $BrowserPort `
                -WorkerId $Id `
                -WorkerIpcDir $IpcDir `
                -BrowserPollSeconds $BrowserPollSeconds `
                -PageIdleSeconds $PageIdleSeconds `
                -PageLoadTimeoutSeconds $PageLoadTimeoutSeconds `
                -MaxLoadAttempts $MaxLoadAttempts `
                -MhtmlRoot $MhtmlRoot
        }
    } -ArgumentList @(
        $scriptPath,
        $script:BrowserPort,
        $Id,
        $IpcDir,
        $TaskKind,
        $BrowserPollSeconds,
        $PageIdleSeconds,
        $PageLoadTimeoutSeconds,
        $MaxLoadAttempts,
        $MhtmlRoot,
        [bool]$LoadImages
    )
}

function Receive-WorkerOutput {
    param($Worker)

    if (-not $Worker -or -not $Worker.Job) {
        return
    }

    Receive-Job -Job $Worker.Job -ErrorAction SilentlyContinue -WarningAction Continue | Out-Host
    if ($Worker.Job.ChildJobs) {
        foreach ($childJob in @($Worker.Job.ChildJobs)) {
            foreach ($errorRecord in @($childJob.Error)) {
                Write-Warning "Worker #$($Worker.Id) error: $($errorRecord.Exception.Message)"
            }
        }
    }
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

function Send-DetailTaskToWorker {
    param(
        $Worker,
        $Item,
        [int]$ItemIndex,
        [int]$TaskId
    )

    $payload = [pscustomobject]@{
        TaskId = $TaskId
        ItemIndex = $ItemIndex
        Url = [string]$Item.url
        Title = [string]$Item.title
        Html = [string]$Item.html
    }

    $tempPath = "$($Worker.TaskPath).tmp"
    $payload | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $Worker.TaskPath -Force

    $Worker.Busy = $true
    $Worker.Task = $Item
    $Worker.TaskId = $TaskId
    $Worker.ItemIndex = $ItemIndex
    Write-Host "Detail worker #$($Worker.Id) proses $ItemIndex/$($Worker.TotalItems): $($Item.url)"
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

    $parentUrlKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($Items)) {
        $url = [string]$item.url
        if (-not [string]::IsNullOrWhiteSpace($url)) {
            [void]$parentUrlKeys.Add((Get-CanonicalUrlKey -PageUrl $url))
        }
    }

    $parentTitleCounts = @{}
    foreach ($item in @($Items)) {
        if (-not $item -or [string]::IsNullOrWhiteSpace([string]$item.url)) {
            continue
        }

        $title = ConvertTo-SafeText ([string]$item.title)
        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = [string]$item.url
        }

        $titleKey = $title.ToLowerInvariant()
        if ($parentTitleCounts.ContainsKey($titleKey)) {
            $parentTitleCounts[$titleKey]++
            $title = "$title`_$($parentTitleCounts[$titleKey])"
        }
        else {
            $parentTitleCounts[$titleKey] = 0
        }

        $href = ConvertTo-XmlAttributeValue ([string]$item.url)
        $label = ConvertTo-XmlAttributeValue $title
        $publishedAt = ConvertTo-XmlAttributeValue ([string]$item.publishedAt)
        $publishedTimestamp = ConvertTo-XmlAttributeValue ([string]$item.publishedTimestamp)
        $children = @($item.children | Where-Object {
            $childUrl = [string]$_.url
            -not [string]::IsNullOrWhiteSpace($childUrl) -and -not $parentUrlKeys.Contains((Get-CanonicalUrlKey -PageUrl $childUrl))
        })
        $linkClass = if ($children.Count -gt 0) { 'contents-table-link is-parent' } else { 'contents-table-link' }
        [void]$lines.Add("`t<li class=""contents-table-item"">")
        [void]$lines.Add("`t`t<div class=""contents-table-el"" data-published-at=""$publishedAt"" data-published-timestamp=""$publishedTimestamp""><a class=""$linkClass"" href=""$href"">$label</a></div>")
        if ($children.Count -gt 0) {
            [void]$lines.Add("`t`t<ul class=""contents-table-list"">")
            foreach ($child in $children) {
                $childUrl = [string]$child.url
                if ([string]::IsNullOrWhiteSpace($childUrl)) {
                    continue
                }

                $childTitle = ConvertTo-SafeText ([string]$child.title)
                if ([string]::IsNullOrWhiteSpace($childTitle)) {
                    $childTitle = $childUrl
                }

                $childHref = ConvertTo-XmlAttributeValue $childUrl
                $childLabel = ConvertTo-XmlAttributeValue $childTitle
                [void]$lines.Add("`t`t`t<li class=""contents-table-item"">")
                [void]$lines.Add("`t`t`t`t<div class=""contents-table-el""><a class=""contents-table-link"" href=""$childHref"">$childLabel</a></div>")
                [void]$lines.Add("`t`t`t</li>")
            }
            [void]$lines.Add("`t`t</ul>")
        }
        [void]$lines.Add("`t</li>")
    }

    [void]$lines.Add('</ul>')
    return [string[]]$lines.ToArray()
}

function ConvertTo-LearningListXml {
    param([object[]]$Items)

    $lines = New-Object System.Collections.ArrayList
    foreach ($item in @($Items)) {
        $html = [string]$item.html
        if ([string]::IsNullOrWhiteSpace($html)) {
            continue
        }

        $publishedAt = ConvertTo-XmlAttributeValue ([string]$item.publishedAt)
        $publishedTimestamp = ConvertTo-XmlAttributeValue ([string]$item.publishedTimestamp)
        [void]$lines.Add("<!-- published_at=""$publishedAt"" published_timestamp=""$publishedTimestamp"" -->")
        [void]$lines.Add($html)
    }

    return [string[]]$lines.ToArray()
}

function ConvertTo-AbsoluteLearningUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ''
    }

    try {
        $uri = [Uri]::new([Uri]'https://dev.epicgames.com', $Url)
        return $uri.AbsoluteUri
    }
    catch {
        return $Url
    }
}

function Get-LearningUrlFromListHtml {
    param([string]$Html)

    if ([string]::IsNullOrWhiteSpace($Html)) {
        return ''
    }

    $matches = [regex]::Matches($Html, '<a\b[^>]*\bhref="([^"]+)"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($match in $matches) {
        $href = [System.Net.WebUtility]::HtmlDecode([string]$match.Groups[1].Value)
        if ($href -match '(?i)(?:^https://dev\.epicgames\.com)?/community/learning/') {
            return ConvertTo-AbsoluteLearningUrl -Url $href
        }
    }

    return ''
}

function Get-LearningListCacheItems {
    param([string]$Path)

    $items = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $pendingPublishedAt = ''
    $pendingPublishedTimestamp = 0
    foreach ($line in Get-Content -LiteralPath $Path) {
        $html = [string]$line
        if ([string]::IsNullOrWhiteSpace($html)) {
            continue
        }

        $commentMatch = [regex]::Match($html, '<!--\s*published_at="([^"]*)"\s+published_timestamp="([^"]*)"\s*-->', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($commentMatch.Success) {
            $pendingPublishedAt = [System.Net.WebUtility]::HtmlDecode([string]$commentMatch.Groups[1].Value)
            $timestampText = [string]$commentMatch.Groups[2].Value
            $timestampValue = 0.0
            [double]::TryParse($timestampText, [ref]$timestampValue) | Out-Null
            $pendingPublishedTimestamp = $timestampValue
            continue
        }

        $url = Get-LearningUrlFromListHtml -Html $html
        if ([string]::IsNullOrWhiteSpace($url)) {
            continue
        }

        [void]$items.Add([pscustomobject]@{
            url = $url
            html = $html
            publishedAt = $pendingPublishedAt
            publishedTimestamp = $pendingPublishedTimestamp
        })
        $pendingPublishedAt = ''
        $pendingPublishedTimestamp = 0
    }

    return @($items)
}

function ConvertFrom-LearningXmlLi {
    param($Li)

    $anchor = $Li.SelectSingleNode("./div[contains(concat(' ', normalize-space(@class), ' '), ' contents-table-el ')]/a")
    if (-not $anchor) {
        return $null
    }

    $children = New-Object System.Collections.ArrayList
    foreach ($childLi in @($Li.SelectNodes("./ul[contains(concat(' ', normalize-space(@class), ' '), ' contents-table-list ')]/li"))) {
        $childAnchor = $childLi.SelectSingleNode("./div[contains(concat(' ', normalize-space(@class), ' '), ' contents-table-el ')]/a")
        if (-not $childAnchor) {
            continue
        }

        [void]$children.Add([pscustomobject]@{
            title = ConvertTo-SafeText ([string]$childAnchor.InnerText)
            url = [string]$childAnchor.GetAttribute('href')
        })
    }

    return [pscustomobject]@{
        title = ConvertTo-SafeText ([string]$anchor.InnerText)
        url = [string]$anchor.GetAttribute('href')
        originalUrl = ''
        html = ''
        publishedAt = [string]$anchor.ParentNode.GetAttribute('data-published-at')
        publishedTimestamp = if ([string]::IsNullOrWhiteSpace([string]$anchor.ParentNode.GetAttribute('data-published-timestamp'))) { 0 } else { [double]$anchor.ParentNode.GetAttribute('data-published-timestamp') }
        children = @($children)
    }
}

function Get-LearningXmlCacheItems {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw
        if ([string]::IsNullOrWhiteSpace($content)) {
            return @()
        }

        [xml]$xml = "<root>$content</root>"
        $items = New-Object System.Collections.ArrayList
        foreach ($li in @($xml.SelectNodes("/root/ul[contains(concat(' ', normalize-space(@class), ' '), ' contents-table-list ')]/li"))) {
            $item = ConvertFrom-LearningXmlLi -Li $li
            if ($item) {
                [void]$items.Add($item)
            }
        }

        return @($items)
    }
    catch {
        Write-Warning "Gagal membaca cache XML learning: $Path - $($_.Exception.Message)"
        return @()
    }
}

function Get-LearningCache {
    param($Target)

    $xmlItems = @(Get-LearningXmlCacheItems -Path ([string]$Target.OutputPath))
    $listItems = @(Get-LearningListCacheItems -Path ([string]$Target.ListOutputPath))
    $byOriginal = @{}
    $byFinal = @{}

    for ($index = 0; $index -lt $xmlItems.Count; $index++) {
        $item = $xmlItems[$index]
        if ($index -lt $listItems.Count) {
            $item.originalUrl = [string]$listItems[$index].url
            $item.html = [string]$listItems[$index].html
            if ([string]::IsNullOrWhiteSpace([string]$item.publishedAt)) {
                $item.publishedAt = [string]$listItems[$index].publishedAt
            }
            if ([double]$item.publishedTimestamp -le 0 -and [double]$listItems[$index].publishedTimestamp -gt 0) {
                $item.publishedTimestamp = [double]$listItems[$index].publishedTimestamp
            }
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$item.originalUrl)) {
            $byOriginal[(Get-CanonicalUrlKey -PageUrl ([string]$item.originalUrl))] = $item
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$item.url)) {
            $byFinal[(Get-CanonicalUrlKey -PageUrl ([string]$item.url))] = $item
        }
    }

    return [pscustomobject]@{
        Items = $xmlItems
        ListItems = $listItems
        ByOriginal = $byOriginal
        ByFinal = $byFinal
    }
}

function Test-LearningItemHasTimestamp {
    param($Item)

    if (-not $Item) {
        return $false
    }

    return [double]$Item.publishedTimestamp -gt 0
}

function Merge-LearningScanWithCache {
    param(
        [object[]]$ScannedItems,
        $Cache
    )

    $newItems = New-Object System.Collections.ArrayList
    $timestampItems = New-Object System.Collections.ArrayList
    $newByOriginal = @{}
    $merged = New-Object System.Collections.ArrayList
    $usedFinalKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $queuedTimestampKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($item in @($ScannedItems)) {
        $url = [string]$item.url
        if ([string]::IsNullOrWhiteSpace($url)) {
            continue
        }

        $key = Get-CanonicalUrlKey -PageUrl $url
        $cached = $null
        if ($Cache.ByOriginal.ContainsKey($key)) {
            $cached = $Cache.ByOriginal[$key]
        }
        elseif ($Cache.ByFinal.ContainsKey($key)) {
            $cached = $Cache.ByFinal[$key]
        }

        if ($cached) {
            if (-not (Test-LearningItemHasTimestamp -Item $cached) -and -not $queuedTimestampKeys.Contains($key)) {
                [void]$timestampItems.Add([pscustomobject]@{
                    title = if ([string]::IsNullOrWhiteSpace([string]$item.title)) { [string]$cached.title } else { [string]$item.title }
                    url = if ([string]::IsNullOrWhiteSpace([string]$item.url)) { if ([string]::IsNullOrWhiteSpace([string]$cached.originalUrl)) { [string]$cached.url } else { [string]$cached.originalUrl } } else { [string]$item.url }
                    html = if ([string]::IsNullOrWhiteSpace([string]$item.html)) { [string]$cached.html } else { [string]$item.html }
                })
                [void]$queuedTimestampKeys.Add($key)
            }
            continue
        }

        [void]$newItems.Add($item)
    }

    $detailItems = @($newItems) + @($timestampItems)
    if ($detailItems.Count -gt 0) {
        if ($newItems.Count -gt 0) {
            Write-Host "Detail scan link baru: $($newItems.Count)"
        }
        if ($timestampItems.Count -gt 0) {
            Write-Host "Detail scan timestamp kosong: $($timestampItems.Count)"
        }

        $newEnrichedItems = @(Invoke-LearningDetailScan -Items @($detailItems))
        foreach ($item in @($newEnrichedItems)) {
            $originalUrl = [string]$item.originalUrl
            if (-not [string]::IsNullOrWhiteSpace($originalUrl)) {
                $newByOriginal[(Get-CanonicalUrlKey -PageUrl $originalUrl)] = $item
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$item.url)) {
                $newByOriginal[(Get-CanonicalUrlKey -PageUrl ([string]$item.url))] = $item
            }
        }
    }
    else {
        Write-Host "Tidak ada link baru atau timestamp kosong untuk detail scan."
    }

    foreach ($item in @($ScannedItems)) {
        $key = Get-CanonicalUrlKey -PageUrl ([string]$item.url)
        $enriched = $null
        if ($newByOriginal.ContainsKey($key)) {
            $enriched = $newByOriginal[$key]
        }
        elseif ($Cache.ByOriginal.ContainsKey($key)) {
            $enriched = $Cache.ByOriginal[$key]
        }
        elseif ($Cache.ByFinal.ContainsKey($key)) {
            $enriched = $Cache.ByFinal[$key]
        }

        if (-not $enriched) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace([string]$enriched.html)) {
            $enriched.html = [string]$item.html
        }
        if ([string]::IsNullOrWhiteSpace([string]$enriched.originalUrl)) {
            $enriched.originalUrl = [string]$item.url
        }

        $finalKey = Get-CanonicalUrlKey -PageUrl ([string]$enriched.url)
        if ($usedFinalKeys.Contains($finalKey)) {
            continue
        }

        [void]$merged.Add($enriched)
        [void]$usedFinalKeys.Add($finalKey)
    }

    return [pscustomobject]@{
        Items = @($merged)
        NewCount = $newItems.Count
        TimestampUpdateCount = $timestampItems.Count
    }
}

function Add-DocumentationXmlItems {
    param(
        [System.Collections.ArrayList]$Lines,
        [object[]]$Items,
        [int]$Depth
    )

    $indent = "`t" * $Depth
    foreach ($item in @($Items)) {
        if (-not $item) {
            continue
        }

        $title = ConvertTo-SafeText ([string]$item.title)
        $href = [string]$item.url
        $children = @($item.children)
        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = $href
        }
        if ([string]::IsNullOrWhiteSpace($title) -and $children.Count -eq 0) {
            continue
        }

        $label = ConvertTo-XmlAttributeValue $title
        $safeHref = ConvertTo-XmlAttributeValue $href
        $linkClass = if ($children.Count -gt 0) { 'contents-table-link is-parent' } else { 'contents-table-link' }

        [void]$Lines.Add("$indent<li class=""contents-table-item"">")
        [void]$Lines.Add("$indent`t<div class=""contents-table-el""><a class=""$linkClass"" href=""$safeHref"">$label</a></div>")

        if ($children.Count -gt 0) {
            [void]$Lines.Add("$indent`t<ul class=""contents-table-list"">")
            Add-DocumentationXmlItems -Lines $Lines -Items $children -Depth ($Depth + 2)
            [void]$Lines.Add("$indent`t</ul>")
        }

        [void]$Lines.Add("$indent</li>")
    }
}

function ConvertTo-DocumentationXml {
    param(
        $Target,
        $Data
    )

    $title = ConvertTo-SafeText ([string]$Data.Title)
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = [string]$Target.Title
    }

    $rootUrl = [string]$Data.FinalUrl
    if ([string]::IsNullOrWhiteSpace($rootUrl)) {
        $rootUrl = [string]$Target.RootUrl
    }

    $lines = New-Object System.Collections.ArrayList
    $items = @($Data.Items)
    if ($items.Count -eq 1) {
        $firstItem = $items[0]
        $firstTitle = ConvertTo-SafeText ([string]$firstItem.title)
        $firstUrl = [string]$firstItem.url
        $firstChildren = @($firstItem.children)
        $isRootWrapper = $firstChildren.Count -gt 0 -and (
            [string]::IsNullOrWhiteSpace($firstUrl) -or
            $firstUrl.TrimEnd('/') -ieq $rootUrl.TrimEnd('/') -or
            $firstTitle -ieq $title
        )

        if ($isRootWrapper) {
            $items = $firstChildren
        }
    }

    [void]$lines.Add(('<div class="contents-table-el is-active is-root-entry"><a class="contents-table-link is-parent" href="{0}">{1}</a></div>' -f (ConvertTo-XmlAttributeValue $rootUrl), (ConvertTo-XmlAttributeValue $title)))
    [void]$lines.Add('<ul class="contents-table-list">')
    Add-DocumentationXmlItems -Lines $lines -Items $items -Depth 1
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

function Invoke-ParallelLearningDetailReads {
    param([object[]]$Items)

    $itemList = @($Items)
    $results = New-Object System.Collections.ArrayList
    if ($itemList.Count -eq 0) {
        return @()
    }

    Ensure-Edge
    Write-Host "Parallel detail aktif: $ParallelPages"

    $queue = New-Object System.Collections.ArrayList
    for ($index = 0; $index -lt $itemList.Count; $index++) {
        [void]$queue.Add([pscustomobject]@{
            Item = $itemList[$index]
            ItemIndex = $index + 1
        })
    }

    $workerIpcDir = Join-Path $MhtmlRoot (".detail-workers-$PID-{0}" -f (Get-Date -Format 'yyyyMMddHHmmss'))
    New-Item -ItemType Directory -Force -Path $workerIpcDir | Out-Null

    $workerCount = [Math]::Min($ParallelPages, $itemList.Count)
    $workers = New-Object System.Collections.ArrayList
    for ($workerId = 1; $workerId -le $workerCount; $workerId++) {
        $job = Start-LearningWorkerJob -Id $workerId -IpcDir $workerIpcDir -TaskKind 'Detail'
        [void]$workers.Add([pscustomobject]@{
            Id = $workerId
            Job = $job
            Busy = $false
            Task = $null
            TaskId = 0
            ItemIndex = 0
            TotalItems = $itemList.Count
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
                        Write-Host "Selesai detail $($result.ItemIndex): $($result.originalUrl) -> $($result.url)"
                    }
                    else {
                        Write-Warning "Detail worker #$($worker.Id) gagal $($result.originalUrl): $($result.Error)"
                    }

                    $worker.Busy = $false
                    $worker.Task = $null
                    $worker.TaskId = 0
                    $worker.ItemIndex = 0
                    $madeProgress = $true
                }
                elseif ($worker.Busy -and $worker.Job.State -ne 'Running') {
                    throw "Detail worker #$($worker.Id) berhenti sebelum mengembalikan hasil"
                }
                elseif (-not $worker.Busy -and $worker.Job.State -ne 'Running') {
                    Clear-WorkerPendingFiles -Worker $worker
                    Remove-Job -Job $worker.Job -Force -ErrorAction SilentlyContinue
                    $worker.Job = Start-LearningWorkerJob -Id $worker.Id -IpcDir $workerIpcDir -TaskKind 'Detail'
                    $madeProgress = $true
                }
            }

            foreach ($worker in @($workers | Where-Object { -not $_.Busy })) {
                if ($queue.Count -eq 0) {
                    break
                }

                $queued = $queue[0]
                $queue.RemoveAt(0)
                $nextTaskId++
                Send-DetailTaskToWorker -Worker $worker -Item $queued.Item -ItemIndex ([int]$queued.ItemIndex) -TaskId $nextTaskId
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

    $seenFinalUrls = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $deduped = New-Object System.Collections.ArrayList
    foreach ($result in @($results | Sort-Object ItemIndex)) {
        $key = Get-CanonicalUrlKey -PageUrl ([string]$result.url)
        if ($seenFinalUrls.Contains($key)) {
            continue
        }
        [void]$seenFinalUrls.Add($key)

        [void]$deduped.Add([pscustomobject]@{
            title = [string]$result.title
            url = [string]$result.url
            originalUrl = [string]$result.originalUrl
            html = [string]$result.html
            publishedAt = [string]$result.publishedAt
            publishedTimestamp = [double]$result.publishedTimestamp
            children = @($result.children)
        })
    }

    return @($deduped | Sort-Object @{ Expression = { [double]$_.publishedTimestamp }; Descending = $true }, @{ Expression = { [string]$_.title }; Ascending = $true })
}

function New-LearningPageTasks {
    param(
        $Target,
        [int]$TotalPages
    )

    $tasks = New-Object System.Collections.ArrayList
    for ($page = 1; $page -le $TotalPages; $page++) {
        [void]$tasks.Add([pscustomobject]@{
            TargetKey = [string]$Target.Key
            Page = $page
            Url = (ConvertTo-PageUrl -RootUrl $Target.RootUrl -Page $page)
        })
    }

    return @($tasks)
}

function Add-LearningUniqueItems {
    param(
        [System.Collections.Specialized.OrderedDictionary]$ItemsByKey,
        [object[]]$PageResults
    )

    $added = 0
    foreach ($result in @($PageResults | Sort-Object Page)) {
        foreach ($item in @($result.Items)) {
            $url = [string]$item.url
            if ([string]::IsNullOrWhiteSpace($url)) {
                continue
            }

            $key = Get-CanonicalUrlKey -PageUrl $url
            if ($ItemsByKey.Contains($key)) {
                continue
            }

            $ItemsByKey.Add($key, $item)
            $added++
        }
    }

    return $added
}

function Invoke-LearningTargetScan {
    param($Target)

    $itemsByKey = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    $totalPages = [Math]::Max(1, [int]$Target.TotalPages)
    $totalResults = [Math]::Max(0, [int]$Target.TotalResults)
    $pass = 0

    while ($true) {
        $pass++
        $scanPages = $totalPages
        if ($MaxPages -gt 0) {
            $scanPages = [Math]::Min($scanPages, $MaxPages)
        }

        Write-Host ""
        Write-Host "Scan $($Target.Key) pass #${pass}: $scanPages page, target total $totalResults link"
        $tasks = @(New-LearningPageTasks -Target $Target -TotalPages $scanPages)
        $pageResults = @(Invoke-ParallelPageReads -Tasks $tasks)

        foreach ($result in @($pageResults)) {
            if ([int]$result.TotalPages -gt $totalPages -and $MaxPages -le 0) {
                $totalPages = [int]$result.TotalPages
            }
            if ([int]$result.TotalResults -gt 0) {
                $totalResults = ConvertTo-LearningTargetTotal -TargetKey ([string]$Target.Key) -TotalResults ([int]$result.TotalResults)
            }
        }

        $added = Add-LearningUniqueItems -ItemsByKey $itemsByKey -PageResults $pageResults
        if ([string]$Target.Key -eq 'LearnUE' -and $itemsByKey.Count -gt $totalResults) {
            $totalResults = $itemsByKey.Count
        }
        Write-Host "Unique $($Target.Key): $($itemsByKey.Count)/$totalResults link (+$added)"

        if ($MaxPages -gt 0) {
            break
        }
        if ($totalResults -le 0 -or $itemsByKey.Count -ge $totalResults) {
            break
        }

        Write-Warning "$($Target.Key): jumlah link belum sampai total result, ulangi dari halaman pertama."
    }

    return [pscustomobject]@{
        Items = @($itemsByKey.Values)
        TotalResults = $totalResults
        TotalPages = $totalPages
        Passes = $pass
    }
}

if ($BuildLearn) {
    foreach ($target in $LearningTargets) {
        Write-Host ""
        $cache = Get-LearningCache -Target $target
        $missingTimestampCount = @($cache.Items | Where-Object { -not (Test-LearningItemHasTimestamp -Item $_) }).Count
        $target | Add-Member -NotePropertyName Cache -NotePropertyValue $cache -Force
        if ($cache.Items.Count -gt 0) {
            Write-Host "Resume cache $($target.Key): $($cache.Items.Count) item XML, $($cache.ListItems.Count) item list, $missingTimestampCount timestamp kosong"
        }

        $learningRootUrl = ConvertTo-LearningRootUrl -RootUrl $target.RootUrl
        Write-Host "Baca root: $learningRootUrl"
        $rootData = Get-LearningPageData -PageUrl $learningRootUrl
        $totalPages = [Math]::Max(1, [int]$rootData.TotalPages)
        if ($MaxPages -gt 0) {
            $totalPages = [Math]::Min($totalPages, $MaxPages)
        }

        $target | Add-Member -NotePropertyName TotalPages -NotePropertyValue $totalPages -Force
        $target | Add-Member -NotePropertyName TotalResults -NotePropertyValue (ConvertTo-LearningTargetTotal -TargetKey ([string]$target.Key) -TotalResults ([int]$rootData.TotalResults)) -Force
        Write-Host "Total page $($target.Key): $totalPages"
        Write-Host "Total result $($target.Key): $($target.TotalResults)"
    }
}

if ($DryRun) {
    Write-Host "DryRun aktif: tidak menulis XML."
    if ($BuildLearn) {
        foreach ($target in $LearningTargets) {
            Write-Host "$($target.Key): $($target.TotalPages) page, $($target.TotalResults) result -> $($target.OutputPath), $($target.ListOutputPath)"
        }
    }
    if ($BuildDoc) {
        foreach ($target in $DocumentationTargets) {
            Write-Host "$($target.Key): documentation TOC -> $($target.OutputPath)"
        }
    }
    Stop-StartedEdge
    if (-not $NoPause) {
        pause
    }
    return
}

if ($BuildLearn) {
    foreach ($target in $LearningTargets) {
        $cache = $target.Cache
        if (-not $cache) {
            $cache = Get-LearningCache -Target $target
        }

        $missingTimestampCount = @($cache.Items | Where-Object { -not (Test-LearningItemHasTimestamp -Item $_) }).Count
        $cacheHasAllLinks = [string]$target.Key -ne 'LearnUE' -and $cache.Items.Count -gt 0 -and [int]$target.TotalResults -gt 0 -and $cache.Items.Count -ge [int]$target.TotalResults
        if ($cacheHasAllLinks) {
            Write-Host ""
            Write-Host "Cache $($target.Key) sudah memenuhi total link ($($cache.Items.Count)/$($target.TotalResults)); skip scan page list."
            $scanResult = [pscustomobject]@{
                Items = @($cache.Items)
                TotalResults = [int]$target.TotalResults
                TotalPages = [int]$target.TotalPages
                Passes = 0
            }
        }
        else {
            $scanResult = Invoke-LearningTargetScan -Target $target
        }

        $mergeResult = Merge-LearningScanWithCache -ScannedItems @($scanResult.Items) -Cache $cache
        $items = @($mergeResult.Items)
        $xmlLines = ConvertTo-LearningXml -Target $target -Items $items
        $listXmlLines = ConvertTo-LearningListXml -Items $items
        Set-Content -LiteralPath $target.OutputPath -Value $xmlLines -Encoding UTF8
        Set-Content -LiteralPath $target.ListOutputPath -Value $listXmlLines -Encoding UTF8
        Write-Host "Tulis XML: $(ConvertTo-RelativeRootPath $target.OutputPath) ($($items.Count)/$($scanResult.TotalResults) link unik, $($mergeResult.NewCount) link baru, $($mergeResult.TimestampUpdateCount) timestamp kosong, $($scanResult.Passes) pass)"
        Write-Host "Tulis XML list: $(ConvertTo-RelativeRootPath $target.ListOutputPath) ($($items.Count) li unik)"
    }
}

if ($BuildDoc) {
    foreach ($target in $DocumentationTargets) {
        Write-Host ""
        Write-Host "Baca documentation TOC: $($target.RootUrl)"
        $documentationData = Get-DocumentationPageData -PageUrl $target.RootUrl
        $xmlLines = ConvertTo-DocumentationXml -Target $target -Data $documentationData
        Set-Content -LiteralPath $target.OutputPath -Value $xmlLines -Encoding UTF8
        Write-Host "Tulis XML: $(ConvertTo-RelativeRootPath $target.OutputPath) ($(@($documentationData.Items).Count) root link, final: $($documentationData.FinalUrl))"
    }
}

Write-Host ""
if ($BuildDoc -and $BuildLearn) {
    Write-Host "Selesai generate XML learning dan documentation."
}
elseif ($BuildDoc) {
    Write-Host "Selesai generate XML documentation."
}
else {
    Write-Host "Selesai generate XML learning."
}
Stop-StartedEdge
if (-not $NoPause) {
    pause
}
