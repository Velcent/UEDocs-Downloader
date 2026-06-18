param(
    [string]$Url = 'https://dev.epicgames.com/documentation/unreal-engine/BlueprintAPI',
    [string]$OutputRoot = (Join-Path $PSScriptRoot 'BlueprintAPI'),
    [int]$BrowserPollSeconds = 1,
    [int]$PageIdleSeconds = 2,
    [int]$PageLoadTimeoutSeconds = 120,
    [int]$MaxLoadAttempts = 3,
    [int]$MaxPages = 0,
    [switch]$Overwrite
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$BrowserPollSeconds = [Math]::Max(1, $BrowserPollSeconds)
$PageIdleSeconds = [Math]::Max(0, $PageIdleSeconds)
$PageLoadTimeoutSeconds = [Math]::Max(1, $PageLoadTimeoutSeconds)
$MaxLoadAttempts = [Math]::Max(1, $MaxLoadAttempts)

$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$ListPath = Join-Path $PSScriptRoot 'mhtml-list.tsv'
$script:BrowserPort = $null
$script:BrowserProfileDir = Join-Path $PSScriptRoot '.edge-profile'
$script:CdpCommandId = 0

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
Set-Content -LiteralPath $ListPath -Value "url`tfinal_url`tfile`ttitle`tchild_count`tparent_url" -Encoding UTF8

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
        (Join-Path $PSScriptRoot ".edge-profile-$PID-$(Get-Date -Format 'yyyyMMddHHmmss')")
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
    } while ($response.id -ne $id)

    if ($response.error) {
        throw "$Method gagal: $($response.error.message)"
    }

    return $response
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

        Write-Host "Menunggu load selesai: attempt=$Attempt ready=$($data.readyState) loading=$($data.loadingCount) stable=$([int]$stableSeconds)s url=$($data.href)"
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

        $data = $null
        for ($attempt = 1; $attempt -le $MaxLoadAttempts; $attempt++) {
            if ($attempt -eq 1) {
                [void](Invoke-CdpCommand -Socket $socket -Method 'Page.navigate' -Params @{ url = $PageUrl })
            }
            else {
                Write-Warning "Reload halaman karena metadata belum lengkap: $PageUrl"
                [void](Invoke-CdpCommand -Socket $socket -Method 'Page.reload' -Params @{ ignoreCache = $true })
            }

            try {
                $data = Wait-BlueprintPageReady -Socket $socket -PageUrl $PageUrl -Attempt $attempt
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

        if ((Test-Path -LiteralPath $filePath) -and -not $Overwrite) {
            Write-Host "Lewati file yang sudah ada: $(ConvertTo-RelativeRootPath $filePath)"
        }
        else {
            $snapshot = Invoke-CdpCommand -Socket $socket -Method 'Page.captureSnapshot' -Params @{ format = 'mhtml' }
            [System.IO.File]::WriteAllText($filePath, [string]$snapshot.result.data, [System.Text.UTF8Encoding]::new($false))
            Write-Host "Simpan MHTML: $(ConvertTo-RelativeRootPath $filePath)"
        }

        return [pscustomobject]@{
            OriginalUrl = $PageUrl
            FinalUrl = [string]$data.href
            Title = [string]$data.h1
            FilePath = $filePath
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

$stack = New-Object System.Collections.ArrayList
$visited = @{}
$downloaded = 0

[void]$stack.Add([pscustomobject]@{
    Url = ([Uri]$Url).AbsoluteUri
    Folder = $OutputRoot
})

while ($stack.Count -gt 0) {
    if ($MaxPages -gt 0 -and $downloaded -ge $MaxPages) {
        Write-Host "MaxPages tercapai: $MaxPages"
        break
    }

    $task = $stack[$stack.Count - 1]
    $stack.RemoveAt($stack.Count - 1)

    $key = Get-CanonicalUrlKey $task.Url
    if ($visited.ContainsKey($key)) {
        continue
    }
    $visited[$key] = $true

    try {
        $result = Save-BlueprintPageAsMhtml -PageUrl $task.Url -Folder $task.Folder
        $downloaded++

        $relativeFile = ConvertTo-RelativeRootPath $result.FilePath
        Add-Content -LiteralPath $ListPath -Value "$($result.OriginalUrl)`t$($result.FinalUrl)`t$relativeFile`t$($result.Title)`t$(@($result.Actions).Count)`t$($result.ParentUrl)" -Encoding UTF8

        $actions = @($result.Actions)
        for ($index = $actions.Count - 1; $index -ge 0; $index--) {
            $action = $actions[$index]
            if ([string]::IsNullOrWhiteSpace([string]$action.url)) {
                continue
            }

            $childFolderName = ConvertTo-SafeSegment -Value $action.name -MaxLength 90
            $childFolder = Join-Path $task.Folder $childFolderName
            [void]$stack.Add([pscustomobject]@{
                Url = [string]$action.url
                Folder = $childFolder
            })
        }
    }
    catch {
        Write-Warning "Gagal memproses: $($task.Url) - $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "Selesai. Total halaman tersimpan/diproses: $downloaded"
Write-Host "Daftar hasil: $ListPath"
pause
