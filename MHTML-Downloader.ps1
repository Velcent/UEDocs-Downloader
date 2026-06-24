param(
    [string]$MhtmlRoot = (Join-Path $PSScriptRoot 'mhtml'),
    [int]$BrowserPollSeconds = 1,
    [double]$PageIdleSeconds = 0.1,
    [int]$PageLoadTimeoutSeconds = 3000,
    [int]$MaxLoadAttempts = 100000,
    [int]$ParallelPages = 5,
    [int]$MaxPages = 0,
    [switch]$Overwrite,
    [switch]$DryRun,
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

$MinimumMhtmlBytes = 650KB
$MhtmlRoot = [System.IO.Path]::GetFullPath($MhtmlRoot)
$script:BrowserPort = if ($WorkerMode) { $WorkerBrowserPort } else { $null }
$script:BrowserProfileDir = Join-Path $MhtmlRoot '.edge-profile'
$script:CdpCommandId = 0
$script:MainDocumentStatus = $null
$script:MainDocumentStatusText = ''
$script:MainDocumentFailedText = ''
$script:MainDocumentRequestId = ''
$script:KnownUrlMapCache = @{}
$script:ApplicationVersionFallbacks = @('5.7', '5.6', '5.5', '5.4', '5.3')

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

    $seen = @{}
    $candidates = New-Object System.Collections.ArrayList
    foreach ($candidate in @($PageUrl) + @($script:ApplicationVersionFallbacks | ForEach-Object { Set-UrlApplicationVersion -PageUrl $PageUrl -Version $_ })) {
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

function Test-UnrealVersionDocumentationRootUrl {
    param([string]$PageUrl)

    if ([string]::IsNullOrWhiteSpace($PageUrl)) {
        return $false
    }

    try {
        $uri = [Uri]$PageUrl
        $path = $uri.AbsolutePath.TrimEnd('/').ToLowerInvariant()
        return $path -match '/documentation/unreal-engine/unreal-engine-5-\d+-documentation$'
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
  const h1 = document.querySelector('h1');
  const htmlLength = document.documentElement?.outerHTML?.length || 0;

  return JSON.stringify({
    href: location.href,
    readyState: document.readyState,
    title: document.title || '',
    h1: normalize(h1?.textContent || ''),
    hasH1: !!h1,
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

function Assert-PageLoadOk {
    param($Data)

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
        throw "HTTP $($script:MainDocumentStatus)$statusText"
    }

    $title = [string]$Data.title
    $h1 = [string]$Data.h1
    $htmlLength = if ($Data.PSObject.Properties['htmlLength']) { [int]$Data.htmlLength } else { 0 }

    if ($h1 -eq 'One more step' -and $htmlLength -lt 102400) {
        throw "Halaman terlihat error challenge: h1='$h1', size=$htmlLength bytes"
    }

    if ("$title $h1" -match '(?i)\b(404|502|503|504|not found|bad gateway|service unavailable|gateway timeout|ERR_[A-Z_]+|DNS|refused|unreachable|timed out|can''t be reached)\b') {
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

        if (Test-UnrealVersionDocumentationRootUrl -PageUrl $finalUrl) {
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

function Get-IndexedSegment {
    param(
        [int]$Index,
        [string]$Title
    )

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
            if (-not [string]::IsNullOrWhiteSpace([string]$row.url)) {
                try {
                    $urlMap[(Get-CanonicalUrlKey ([string]$row.url))] = $true
                }
                catch {
                }
            }
        }
    }

    return [pscustomobject]@{
        UrlMap = $urlMap
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

        $filePath = ConvertTo-LocalPathFromListValue ([string]$row.file)
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

    $title = Get-NormalizedText ([string]$anchor.InnerText)
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = $url
    }

    $segment = Get-IndexedSegment -Index $Index -Title $title
    $nodeFolder = [System.IO.Path]::GetFullPath((Join-Path $ParentFolder $segment))
    $filePath = Join-Path $ParentFolder "$segment.mhtml"

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
    $xmlFiles = @(Get-ChildItem -LiteralPath $Root -File -Filter '*.xml' | Sort-Object Name)
    Write-Host "XML langsung di folder mhtml: $($xmlFiles.Count) file"

    foreach ($xmlFile in $xmlFiles) {
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
    $groups = @($Tasks | Group-Object -Property SourceXml)
    foreach ($group in $groups) {
        $linkPath = Get-IndexPathForXml -SourceXml $group.Name -Kind 'link'
        if ((Test-Path -LiteralPath $linkPath) -and (Get-Item -LiteralPath $linkPath).Length -gt 0) {
            [void]$writtenPaths.Add($linkPath)
            continue
        }

        $rows = New-Object System.Collections.ArrayList
        [void]$rows.Add("url`tsave_folder`tfile`ttitle`tchild_count`tparent_url`tsource_xml")
        foreach ($task in @($group.Group)) {
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

function Save-MhtmlPageInSession {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        $Task
    )

    $pageUrl = [string]$Task.Url
    $filePath = [System.IO.Path]::GetFullPath([string]$Task.FilePath)
    $folder = [System.IO.Path]::GetDirectoryName($filePath)
    $saved = $false
    $data = $null
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
            Assert-PageLoadOk -Data $data
            Assert-FinalUrlDoesNotPointToKnownDifferentPage -Task $Task -Data $data

            New-Item -ItemType Directory -Force -Path $folder | Out-Null
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

    $title = if ($data -and -not [string]::IsNullOrWhiteSpace([string]$data.h1)) { [string]$data.h1 } else { [string]$Task.Title }
    $finalUrl = if ($data -and -not [string]::IsNullOrWhiteSpace([string]$data.href)) { [string]$data.href } else { $pageUrl }

    return [pscustomobject]@{
        OriginalUrl = $pageUrl
        FinalUrl = $finalUrl
        Title = $title
        FilePath = $filePath
        Saved = $saved
        ChildCount = [int]$Task.ChildCount
        ParentUrl = [string]$Task.ParentUrl
        SourceXml = [string]$Task.SourceXml
    }
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
        ChildCount = $Result.ChildCount
        ParentUrl = $Result.ParentUrl
        SourceXml = $Result.SourceXml
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
        $session = New-MhtmlPageSession
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

    if ($urlKey -and $ResumeMap.UrlMap.ContainsKey($urlKey)) {
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
            [bool]$OverwriteFlag,
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
            -Overwrite:$OverwriteFlag `
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
        $Overwrite.IsPresent,
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
            $result = Save-MhtmlPage -Task $task
            $result | Add-Member -NotePropertyName RelativeFile -NotePropertyValue (ConvertTo-RelativeRootPath $result.FilePath) -Force
            $downloaded++
            Add-DownloadedResultToList -Result $result -ResumeMap $downloadedResumeMap
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
                        $downloaded++
                        Add-DownloadedResultToList -Result $result -ResumeMap $downloadedResumeMap

                        Write-Host "Simpan: $($result.RelativeFile)"
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
