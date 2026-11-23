param(
    [string]$Url = 'https://dev.epicgames.com/documentation/unreal-engine/BlueprintAPI?application_version=5.8',
    [string]$OutputRoot = (Join-Path $PSScriptRoot 'mhtml\BlueprintAPI'),
    [int]$BrowserPollSeconds = 1,
    [float]$PageIdleSeconds = .1,
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

$MinimumMhtmlBytes = 680KB
$MhtmlRoot = Join-Path $PSScriptRoot 'mhtml'
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$ListPath = Join-Path $MhtmlRoot 'bp_api-list.tsv'
$ListBackupPath = Join-Path $MhtmlRoot 'bp_api-list.bak'
$LinkPath = Join-Path $MhtmlRoot 'bp_api-link.tsv'
$LinkBackupPath = Join-Path $MhtmlRoot 'bp_api-link.bak'
$script:BrowserPort = if ($WorkerMode) { $WorkerBrowserPort } else { $null }
$script:BrowserProfileDir = Join-Path $PSScriptRoot '.browser-profile'
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
            '--disable-backgrounding-occluded-windows',
            '--disable-extensions',
            '--disable-renderer-backgrounding',
            '--disable-features=msSleepingTabs,msSleepingTabsAvailable,msFadeSleepingTabs,msEdgeSleepingTabs,EdgeSleepingTabs,TabFreeze,TabDiscarding,AutomaticTabDiscarding,PerformanceDetector',
            '--no-first-run',
            '--start-maximized',
            '--new-window',
            'about:blank'
        )

        Start-Process -FilePath $edgePath -ArgumentList $arguments | Out-Null

        try {
            Wait-DevTools -Port $script:BrowserPort
            $script:BrowserProfileDir = $profileDir
            $firstTab = Wait-FirstPageTarget -TimeoutSeconds 15
            if (-not $firstTab) { $firstTab = Open-DevToolsUrl 'about:blank' }
            Save-ChallengeTargetId -TargetId ([string]$firstTab.id)
            Set-ChallengeTabMarker -TargetId ([string]$firstTab.id)
            Write-Host "Tab challenge siap: $($firstTab.id)"
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

    $title = [string]$Data.title
    $h1 = [string]$Data.h1
    $htmlLength = if ($Data.PSObject.Properties['htmlLength']) { [int]$Data.htmlLength } else { 0 }

    if ($h1 -eq 'One more step' -and $htmlLength -lt 102400) {
        [void](Resolve-CloudflareChallenge -DetectedAt ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
        throw "Halaman terlihat error challenge: h1='$h1', size=$htmlLength bytes"
    }

    if ($null -ne $script:MainDocumentStatus -and $script:MainDocumentStatus -ge 400) {
        $statusText = if ($script:MainDocumentStatusText) { " $($script:MainDocumentStatusText)" } else { '' }
        throw "HTTP $($script:MainDocumentStatus)$statusText"
    }

    $allowPattern = '^(?i)(?:' +
        'On Connection Error' +
        '|Get Last Multi-User Connection Error' +
        ')$'

    $errorPattern = '(?i)\b(?:' +
        '404|502|503|504' +
        '|not\s+found' +
        '|bad\s+gateway' +
        '|service\s+(?:temporarily\s+)?unavailable' +
        '|gateway\s+time[-\s]?out' +
        '|ERR_[A-Z_]+' +
        '|DNS_(?:PROBE|RESOLUTION|LOOKUP)[A-Z_]*' +
        '|(?:no|lost)\s+internet' +
        '|internet\s+(?:disconnected|not\s+available)' +
        '|connection\s+(?:refused|reset|closed|failed|timed\s+out|error)' +
        '|refused\s+to\s+connect' +
        '|unreachable' +
        '|took\s+too\s+long\s+to\s+respond' +
        '|can(?:not|''t)\s+(?:be\s+reached|reach\s+this\s+(?:page|site))' +
        ')\b'

    if ("$h1" -notmatch $allowPattern -and "$title $h1" -match $errorPattern) {
        throw "Halaman terlihat error: title='$title', h1='$h1'"
    }
}

# ==================== CLOUDFLARE CHALLENGE SOLVER ====================
if (-not ('Win32.NativeInput' -as [type])) {
    Add-Type -Namespace Win32 -Name NativeInput -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
[StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
[StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION U; }
[DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);
[DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
'@
}
$script:InputSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][Win32.NativeInput+INPUT])

function Send-RealMouseMove {
    param([int]$X, [int]$Y)
    $vsX = [Win32.NativeInput]::GetSystemMetrics(76); $vsY = [Win32.NativeInput]::GetSystemMetrics(77)
    $vsW = [Win32.NativeInput]::GetSystemMetrics(78); $vsH = [Win32.NativeInput]::GetSystemMetrics(79)
    $inp = New-Object Win32.NativeInput+INPUT
    $inp.type = 0
    $inp.U.mi.dx = [int](($X - $vsX) * 65535.0 / [Math]::Max(1, $vsW - 1))
    $inp.U.mi.dy = [int](($Y - $vsY) * 65535.0 / [Math]::Max(1, $vsH - 1))
    $inp.U.mi.dwFlags = 0x0001 -bor 0x8000   # MOVE | ABSOLUTE
    [void][Win32.NativeInput]::SendInput(1, @($inp), $script:InputSize)
}

function Send-RealMousePath {
    param([int]$ToX, [int]$ToY)
    $cur = New-Object Win32.NativeInput+POINT
    [void][Win32.NativeInput]::GetCursorPos([ref]$cur)
    $steps = Get-Random -Minimum 12 -Maximum 26
    for ($i = 1; $i -le $steps; $i++) {
        $t = $i / $steps
        $ease = $t * $t * (3 - 2 * $t)   # smoothstep, bukan linier
        $x = $cur.X + ($ToX - $cur.X) * $ease + (Get-Random -Minimum -3 -Maximum 4)
        $y = $cur.Y + ($ToY - $cur.Y) * $ease + (Get-Random -Minimum -2 -Maximum 3)
        Send-RealMouseMove -X [int]$x -Y [int]$y
        Start-Sleep -Milliseconds (Get-Random -Minimum 8 -Maximum 30)
    }
}

function Send-RealKey {
    param([ushort]$Vk, [bool]$Ctrl = $false)
    $list = New-Object System.Collections.Generic.List[Win32.NativeInput+INPUT]
    $mk = { param($vk, $up) $i = New-Object Win32.NativeInput+INPUT; $i.type = 1; $i.U.ki.wVk = $vk; if ($up) { $i.U.ki.dwFlags = 2 }; $i }
    if ($Ctrl) { $list.Add((& $mk 0x11 $false)) }
    $list.Add((& $mk $Vk $false)); $list.Add((& $mk $Vk $true))
    if ($Ctrl) { $list.Add((& $mk 0x11 $true)) }
    [void][Win32.NativeInput]::SendInput([uint]$list.Count, $list.ToArray(), $script:InputSize)
}

function Send-RealReload { Send-RealKey -Vk 0x74 }   # F5 asli (ada user-activation)

function Get-ScriptEdgeWindowHandle {
    $profile = $script:BrowserProfileDir
    $proc = Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" |
        Where-Object { $_.CommandLine -like "*--user-data-dir=$profile*" -and $_.CommandLine -like '*--remote-debugging-port*' } |
        Select-Object -First 1
    if (-not $proc) { return [IntPtr]::Zero }
    $p = Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue
    if ($p) { return $p.MainWindowHandle }
    return [IntPtr]::Zero
}

function Set-EdgeForeground {
    $hwnd = Get-ScriptEdgeWindowHandle
    if ($hwnd -ne [IntPtr]::Zero) {
        [void][Win32.NativeInput]::ShowWindow($hwnd, 9)   # SW_RESTORE
        [void][Win32.NativeInput]::SetForegroundWindow($hwnd)
    }
}

function Get-ViewportScreenOrigin {
    $hwnd = Get-ScriptEdgeWindowHandle
    if ($hwnd -eq [IntPtr]::Zero) { return $null }
    $render = [Win32.NativeInput]::FindWindowEx($hwnd, [IntPtr]::Zero, 'Chrome_RenderWidgetHostHWND', $null)
    if ($render -eq [IntPtr]::Zero) { return $null }
    $pt = New-Object Win32.NativeInput+POINT
    [void][Win32.NativeInput]::ClientToScreen($render, [ref]$pt)
    $dpi = [Win32.NativeInput]::GetDpiForWindow($render)
    $scale = if ($dpi -gt 0) { $dpi / 96.0 } else { 1.0 }
    return [pscustomobject]@{ X = $pt.X; Y = $pt.Y; Scale = $scale }
}

function Get-ChallengeConfig {
    return [pscustomobject]@{
        Enabled             = $true
        Url                 = 'https://dev.epicgames.com/documentation/404'
        ReloadMax           = 60
        PageWaitSeconds     = 8
        SolveTimeout        = 240
        CooldownSeconds     = 30
        MaxClickTotal       = 12
        ClickGapSeconds     = 2.5
        AutoClickEnabled    = $false
        WarmupEnabled       = $true
        FocusEmulationEnabled = $false
    }
}

function Get-ChallengePaths {
    return [pscustomobject]@{
        Tab   = Join-Path $WorkerIpcDir '.challenge-tab.json'
        State = Join-Path $WorkerIpcDir '.challenge-state.json'
        Lock  = Join-Path $WorkerIpcDir '.challenge.lock'
    }
}

function Get-DevToolsTargetList {
    if (-not $script:BrowserPort) { return @() }
    try { return @(Invoke-RestMethod -Uri "http://127.0.0.1:$($script:BrowserPort)/json/list" -ErrorAction Stop) }
    catch { return @() }
}

function Read-ChallengeState {
    $default = [pscustomobject]@{ solvedAt = [int64]0; failedAt = [int64]0 }
    $path = (Get-ChallengePaths).State
    if (-not (Test-Path -LiteralPath $path)) { return $default }
    try {
        $s = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
        return [pscustomobject]@{ solvedAt = [int64]$s.solvedAt; failedAt = [int64]$s.failedAt }
    } catch { return $default }
}

function Write-ChallengeState {
    param([int64]$SolvedAt = -1, [int64]$FailedAt = -1)
    $path = (Get-ChallengePaths).State
    $state = Read-ChallengeState
    if ($SolvedAt -ge 0) { $state.solvedAt = $SolvedAt }
    if ($FailedAt -ge 0) { $state.failedAt = $FailedAt }
    try {
        $tmp = "$path.$PID.tmp"
        $state | ConvertTo-Json -Compress | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } catch { }
}

function Get-ChallengeLockInfo {
    $path = (Get-ChallengePaths).Lock
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json) }
    catch { return $null }
}

function Enter-ChallengeLock {
    param([int]$WaitSeconds = 0, [int]$StaleSeconds = 360)
    $path = (Get-ChallengePaths).Lock
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $staleRetries = 0
    while ($true) {
        try {
            $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
            $info = @{ pid = $PID; startedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } | ConvertTo-Json -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($info)
            $fs.Write($bytes, 0, $bytes.Length); $fs.Flush()
            return $fs
        }
        catch {
            $stale = $false
            $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
            if ($item) {
                $age = ((Get-Date) - $item.LastWriteTime).TotalSeconds
                $info = Get-ChallengeLockInfo
                $ownerPid = if ($info -and $info.pid) { [int]$info.pid } else { 0 }
                $ownerAlive = $false
                if ($ownerPid -gt 0) { $ownerAlive = [bool](Get-Process -Id $ownerPid -ErrorAction SilentlyContinue) }
                if ($age -gt $StaleSeconds -or ($ownerPid -gt 0 -and -not $ownerAlive)) { $stale = $true }
            }
            if ($stale -and $staleRetries -lt 3) {
                $staleRetries++
                Write-Warning 'Challenge: lock basi dibersihkan.'
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                continue   # langsung coba ambil lagi setelah dibersihkan
            }
            if ((Get-Date) -ge $deadline) { return $null }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Exit-ChallengeLock {
    param($Stream)
    if ($Stream) { try { $Stream.Dispose() } catch { } }
    Remove-Item -LiteralPath (Get-ChallengePaths).Lock -Force -ErrorAction SilentlyContinue
}

function Save-ChallengeTargetId {
    param([string]$TargetId)
    if ([string]::IsNullOrWhiteSpace($TargetId)) { return }
    try {
        @{ port = $script:BrowserPort; targetId = $TargetId } | ConvertTo-Json -Compress |
            Set-Content -LiteralPath (Get-ChallengePaths).Tab -Encoding UTF8
    } catch { }
}

function Get-ChallengeTargetId {
    $targets = Get-DevToolsTargetList
    $tabPath = (Get-ChallengePaths).Tab
    $known = ''
    if (Test-Path -LiteralPath $tabPath) {
        try { $known = [string]((Get-Content -LiteralPath $tabPath -Raw | ConvertFrom-Json).targetId) } catch { }
    }
    if ($known -and @($targets | Where-Object { $_.id -eq $known -and $_.type -eq 'page' }).Count -gt 0) { return $known }
    $marked = @($targets | Where-Object { $_.type -eq 'page' -and [string]$_.url -like 'about:blank#bp-challenge*' })
    if ($marked.Count -gt 0) { Save-ChallengeTargetId -TargetId $marked[0].id; return [string]$marked[0].id }
    $blank = @($targets | Where-Object { $_.type -eq 'page' -and ([string]$_.url -eq 'about:blank' -or [string]::IsNullOrWhiteSpace([string]$_.url)) } | Select-Object -Last 1)
    if ($blank.Count -gt 0) { Save-ChallengeTargetId -TargetId $blank[0].id; return [string]$blank[0].id }
    $page = Open-DevToolsUrl 'about:blank'
    Save-ChallengeTargetId -TargetId $page.id
    return [string]$page.id
}

function Wait-FirstPageTarget {
    param([int]$TimeoutSeconds = 15)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $pages = @(Get-DevToolsTargetList | Where-Object { $_.type -eq 'page' })
        if ($pages.Count -gt 0) {
            $blank = @($pages | Where-Object { [string]$_.url -like 'about:blank*' -or [string]::IsNullOrWhiteSpace([string]$_.url) })
            if ($blank.Count -gt 0) { return $blank[0] }
            return $pages[0]
        }
        Start-Sleep -Milliseconds 300
    }
    return $null
}

function Set-ChallengeTabMarker {
    param([string]$TargetId)
    if ([string]::IsNullOrWhiteSpace($TargetId)) { return }
    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    try {
        [void]$socket.ConnectAsync([Uri]"ws://127.0.0.1:$($script:BrowserPort)/devtools/page/$TargetId", [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        [void](Invoke-CdpCommand -Socket $socket -Method 'Page.navigate' -Params @{ url = 'about:blank#bp-challenge' })
    }
    catch { Write-Warning "Gagal menandai tab challenge: $($_.Exception.Message)" }
    finally { $socket.Dispose() }
}

function Get-ChallengeClickPointViaFrameTree {
    param([System.Net.WebSockets.ClientWebSocket]$Socket)
    try {
        $treeResp = Invoke-CdpCommand -Socket $Socket -Method 'Page.getFrameTree'
        $pending = New-Object System.Collections.ArrayList
        [void]$pending.Add($treeResp.result.frameTree)
        while ($pending.Count -gt 0) {
            $node = $pending[0]
            $pending.RemoveAt(0)
            if (-not $node) { continue }
            $frameUrl = [string]$node.frame.url
            if ($frameUrl -match '(?i)challenges\.cloudflare\.com|cdn-cgi/challenge-platform|turnstile') {
                try {
                    $owner = Invoke-CdpCommand -Socket $Socket -Method 'DOM.getFrameOwner' -Params @{ frameId = [string]$node.frame.id }
                    $backendNodeId = [int64]$owner.result.backendNodeId
                    if ($backendNodeId -gt 0) {
                        try { [void](Invoke-CdpCommand -Socket $Socket -Method 'DOM.scrollIntoViewIfNeeded' -Params @{ backendNodeId = $backendNodeId }) } catch { }
                        $box = Invoke-CdpCommand -Socket $Socket -Method 'DOM.getBoxModel' -Params @{ backendNodeId = $backendNodeId }
                        $quad = @($box.result.model.content)
                        $width = [double]$box.result.model.width
                        $height = [double]$box.result.model.height
                        if ($quad.Count -ge 8 -and $width -gt 0 -and $height -gt 0) {
                            $offset = [Math]::Min(32, [Math]::Max(20, $width * 0.1))
                            return [pscustomobject]@{
                                x = [double]$quad[0] + $offset
                                y = [double]$quad[1] + $height / 2
                                source = 'iframe-cdp'
                                src = $frameUrl
                            }
                        }
                    }
                } catch { }
            }
            foreach ($child in @($node.childFrames)) { [void]$pending.Add($child) }
        }
    } catch { }
    return $null
}

function New-ChallengeTabSession {
    $targetId = Get-ChallengeTargetId
    if ([string]::IsNullOrWhiteSpace($targetId)) { throw 'Tab challenge tidak ditemukan.' }
    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    [void]$socket.ConnectAsync([Uri]"ws://127.0.0.1:$($script:BrowserPort)/devtools/page/$targetId", [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    try {
        [void](Invoke-CdpCommand -Socket $socket -Method 'Page.enable')
        [void](Invoke-CdpCommand -Socket $socket -Method 'Runtime.enable')
        [void](Invoke-CdpCommand -Socket $socket -Method 'DOM.enable')
        $cfg = Get-ChallengeConfig
        if ($cfg.FocusEmulationEnabled) {
            [void](Invoke-CdpCommand -Socket $socket -Method 'Emulation.setFocusEmulationEnabled' -Params @{ enabled = $true })
        }
        try { [void](Invoke-CdpCommand -Socket $socket -Method 'Page.setWebLifecycleState' -Params @{ state = 'active' }) } catch { }
        return [pscustomobject]@{ TargetId = $targetId; Socket = $socket }
    }
    catch { $socket.Dispose(); throw }
}

function Get-ChallengeProbeExpression {
    return @'
(() => {
    const norm = (v) => (v || '').replace(/\s+/g, ' ').trim();
    const visible = (el) => {
        if (!el) return false;
        const s = getComputedStyle(el);
        if (s.display === 'none' || s.visibility === 'hidden' || Number(s.opacity) === 0) return false;
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
    };
    const walk = (root, out, depth) => {
        if (!root || depth > 12 || !root.querySelectorAll) return;
        for (const el of root.querySelectorAll('*')) {
            out.push(el);
            if (el.shadowRoot) walk(el.shadowRoot, out, depth + 1);
        }
    };
    const all = [];
    walk(document, all, 0);
    const bodyText = norm(document.body ? document.body.innerText : '');
    const h1 = document.querySelector('h1');
    const h1Text = norm(h1 ? h1.textContent : '');
    const looksLikeChallenge = /one more step|just a moment|verify you are human|checking your browser|needs to review the security|enable javascript and cookies|security check to continue/i.test(document.title + ' ' + bodyText);
    const verificationSuccessful = /verification successful/i.test(document.title + ' ' + bodyText);
    const challengeSelector = '#challenge-form,#challenge-stage,#challenge-running,.cf-turnstile,[data-sitekey]';
    const hasChallengeForm = !!document.querySelector(challengeSelector) ||
        all.some((el) => el.matches && el.matches(challengeSelector));
    const tokens = all.filter((el) => el.tagName === 'INPUT' &&
        (/^cf-chl-widget-.*_response$/.test(el.id || '') || el.name === 'cf-turnstile-response'));
    const token = tokens.map((el) => String(el.value || '')).find((v) => v.length > 0) || '';
    let point = null;
    const cb = all.find((el) => el.tagName === 'INPUT' && (el.type || '').toLowerCase() === 'checkbox' && visible(el));
    if (cb) {
        const r = cb.getBoundingClientRect();
        point = { x: r.x + r.width / 2, y: r.y + r.height / 2, source: 'checkbox' };
    }
    if (!point) {
        const frames = all.filter((el) => el.tagName === 'IFRAME' && visible(el));
        const cf = frames.find((el) => /challenges\.cloudflare\.com|cdn-cgi\/challenge-platform|turnstile/i.test(el.src || ''));
        const target = cf || (looksLikeChallenge ? frames[0] : null);
        if (target) {
            const r = target.getBoundingClientRect();
            point = { x: r.x + Math.min(32, Math.max(20, r.width * 0.1)), y: r.y + r.height / 2, source: 'iframe', src: target.src || '' };
        }
    }
    return JSON.stringify({
        href: location.href,
        readyState: document.readyState,
        title: document.title || '',
        h1: h1Text,
        htmlLength: ((document.documentElement && document.documentElement.outerHTML) || '').length,
        hasChallengeForm,
        looksLikeChallenge,
        verificationSuccessful,
        token,
        click: point
    });
})()
'@
}

function Get-TurnstileWidgetState {
    param([System.Net.WebSockets.ClientWebSocket]$Socket)
    try {
        $tree = Invoke-CdpCommand -Socket $Socket -Method 'Page.getFrameTree'
        $pending = New-Object System.Collections.ArrayList
        [void]$pending.Add($tree.result.frameTree)
        while ($pending.Count -gt 0) {
            $node = $pending[0]; $pending.RemoveAt(0)
            if (-not $node) { continue }
            $frameUrl = [string]$node.frame.url
            if ($frameUrl -match '(?i)challenges\.cloudflare\.com|cdn-cgi/challenge-platform|turnstile') {
                try {
                    $owner = Invoke-CdpCommand -Socket $Socket -Method 'DOM.getFrameOwner' -Params @{ frameId = [string]$node.frame.id }
                    $bnid = [int64]$owner.result.backendNodeId
                    if ($bnid -gt 0) {
                        try { [void](Invoke-CdpCommand -Socket $Socket -Method 'DOM.scrollIntoViewIfNeeded' -Params @{ backendNodeId = $bnid }) } catch { }
                        $box = Invoke-CdpCommand -Socket $Socket -Method 'DOM.getBoxModel' -Params @{ backendNodeId = $bnid }
                        $quad = @($box.result.model.content)
                        $w = [double]$box.result.model.width
                        $h = [double]$box.result.model.height
                        if ($quad.Count -ge 8 -and $w -gt 0 -and $h -gt 0) {
                            $ox = [double]$quad[0]; $oy = [double]$quad[1]
                            # Cari checkbox ASLI di dalam iframe (bukan label).
                            $inner = $null
                            try {
                                $world = Invoke-CdpCommand -Socket $Socket -Method 'Page.createIsolatedWorld' -Params @{ frameId = [string]$node.frame.id; worldName = 'bp_probe' }
                                $ctx = [int]$world.result.executionContextId
                                $expr = @'
(() => {
    const vis = (el) => {
        if (!el) return null;
        const r = el.getBoundingClientRect();
        return (r.width > 0 && r.height > 0) ? { x: r.x, y: r.y, w: r.width, h: r.height } : null;
    };
    const cbs = [...document.querySelectorAll('input[type=checkbox], [role=checkbox]')];
    for (const el of cbs) { const r = vis(el); if (r) return JSON.stringify(r); }
    return '';
})()
'@
                                $resp = Invoke-CdpCommand -Socket $Socket -Method 'Runtime.evaluate' -Params @{ expression = $expr; contextId = $ctx; returnByValue = $true }
                                $val = [string]$resp.result.result.value
                                if ($val) { $inner = $val | ConvertFrom-Json }
                            } catch { }
                            $hasCheckbox = $false; $cx = 0.0; $cy = 0.0; $source = ''
                            if ($inner) {
                                $hasCheckbox = $true
                                $cx = $ox + [double]$inner.x + [double]$inner.w / 2
                                $cy = $oy + [double]$inner.y + [double]$inner.h / 2
                                $source = 'checkbox-iframe'
                            }
                            elseif ($w -ge 250 -and $h -ge 50) {
                                # Widget penuh = checkbox sudah render walau input tak terbaca.
                                $hasCheckbox = $true
                                $cx = $ox + [Math]::Min(32, [Math]::Max(20, $w * 0.1))
                                $cy = $oy + $h / 2
                                $source = 'widget-size'
                            }
                            # else: widget masih label kecil -> HasCheckbox false, warmup saja.
                            return [pscustomobject]@{
                                FrameX = $ox; FrameY = $oy; FrameW = $w; FrameH = $h
                                HasCheckbox = $hasCheckbox
                                ClickX = $cx; ClickY = $cy
                                Source = $source
                            }
                        }
                    }
                } catch { }
            }
            foreach ($child in @($node.childFrames)) { [void]$pending.Add($child) }
        }
    } catch { }
    return $null
}

function Invoke-TrustedMouseClick {
    param([System.Net.WebSockets.ClientWebSocket]$Socket, [double]$X, [double]$Y)
    [void](Invoke-CdpCommand -Socket $Socket -Method 'Input.dispatchMouseEvent' -Params @{ type = 'mouseMoved'; x = $X; y = $Y; button = 'none'; buttons = 0 })
    Start-Sleep -Milliseconds (Get-Random -Minimum 60 -Maximum 160)
    [void](Invoke-CdpCommand -Socket $Socket -Method 'Input.dispatchMouseEvent' -Params @{ type = 'mousePressed'; x = $X; y = $Y; button = 'left'; buttons = 1; clickCount = 1 })
    Start-Sleep -Milliseconds (Get-Random -Minimum 50 -Maximum 130)
    [void](Invoke-CdpCommand -Socket $Socket -Method 'Input.dispatchMouseEvent' -Params @{ type = 'mouseReleased'; x = $X; y = $Y; button = 'left'; buttons = 0; clickCount = 1 })
}

function Invoke-ChallengeMouseWarmup {
    param([System.Net.WebSockets.ClientWebSocket]$Socket, [double]$X = 0, [double]$Y = 0)
    $targetX = if ($X -gt 0) { $X } else { 480 + (Get-Random -Minimum -60 -Maximum 60) }
    $targetY = if ($Y -gt 0) { $Y } else { 320 + (Get-Random -Minimum -40 -Maximum 40) }
    $startX = $targetX + (Get-Random -Minimum 140 -Maximum 320)
    $startY = $targetY + (Get-Random -Minimum 60 -Maximum 160)
    $steps = Get-Random -Minimum 5 -Maximum 10
    for ($i = 1; $i -le $steps; $i++) {
        $t = $i / $steps
        $x = $startX + ($targetX - $startX) * $t + (Get-Random -Minimum -5 -Maximum 6)
        $y = $startY + ($targetY - $startY) * $t + (Get-Random -Minimum -4 -Maximum 5)
        [void](Invoke-CdpCommand -Socket $Socket -Method 'Input.dispatchMouseEvent' -Params @{
            type = 'mouseMoved'; x = $x; y = $y; button = 'none'; buttons = 0
        })
        Start-Sleep -Milliseconds (Get-Random -Minimum 30 -Maximum 110)
    }
}

function Get-ClearanceCookieValue {
    param([System.Net.WebSockets.ClientWebSocket]$Socket, [string]$ProbeUrl)
    try {
        $resp = Invoke-CdpCommand -Socket $Socket -Method 'Network.getCookies' -Params @{ urls = @($ProbeUrl) }
        $cookie = @($resp.result.cookies | Where-Object { $_.name -eq 'cf_clearance' }) | Select-Object -First 1
        if ($cookie) { return [string]$cookie.value }
    } catch { }
    return ''
}

function Invoke-CloudflareChallengeLoop {
    param([System.Net.WebSockets.ClientWebSocket]$Socket, $Config)

    $expression   = Get-ChallengeProbeExpression
    $cookieBefore = Get-ClearanceCookieValue -Socket $Socket -ProbeUrl $Config.Url
    $deadline     = (Get-Date).AddSeconds($Config.SolveTimeout)

    $sawChallenge = $false
    $cleanStreak  = 0
    $clickCount   = 0
    $lastClickAt  = [datetime]::MinValue
    $lastWarmupAt = [datetime]::MinValue
    $lastFrontAt  = [datetime]::MinValue
    $reloadCount  = 0
    $tokenLogged  = $false
    $navigated    = $false
    $loadDeadline = [datetime]::MinValue

    while ((Get-Date) -lt $deadline) {
        if (-not $navigated) {
            [void](Invoke-CdpCommand -Socket $Socket -Method 'Page.bringToFront')
            Write-Host "Challenge: buka $($Config.Url)"
            [void](Invoke-CdpCommand -Socket $Socket -Method 'Page.navigate' -Params @{ url = $Config.Url })
            $navigated    = $true
            $lastFrontAt  = Get-Date
            $loadDeadline = (Get-Date).AddSeconds($Config.PageWaitSeconds)
        }
        elseif (-not $sawChallenge -and (Get-Date) -ge $loadDeadline) {
            if ($reloadCount -ge $Config.ReloadMax) {
                Write-Warning "Challenge: reload max, h1 'One more step' tidak muncul juga."
                break
            }
            $reloadCount++
            $cleanStreak = 0
            Write-Host "Challenge: reload ke-$reloadCount (h1 'One more step' belum muncul)"
            # [void](Invoke-CdpCommand -Socket $Socket -Method 'Page.reload' -Params @{ ignoreCache = $true })
            Set-EdgeForeground
            Send-RealReload
            $loadDeadline = (Get-Date).AddSeconds($Config.PageWaitSeconds)
        }

        Start-Sleep -Milliseconds 800

        try { $probe = (Invoke-PageEval -Socket $Socket -Expression $expression) | ConvertFrom-Json }
        catch { continue }

        if ([bool]$probe.verificationSuccessful) {
            Write-Host 'Challenge: "Verification successful" muncul -> selesai.'
            return $true
        }

        $h1 = [string]$probe.h1
        $isChallenge = ($h1 -match '(?i)one more step') -or
            [bool]$probe.looksLikeChallenge -or
            [bool]$probe.hasChallengeForm -or
            ($null -ne $probe.click)

        if ($isChallenge) {
            if (-not $sawChallenge) {
                Write-Host "Challenge: h1 '$h1' muncul -> STOP reload, mode pasif (klik/warmup/focus-emulation OFF)."
            }
            $sawChallenge = $true
            $cleanStreak  = 0

            $cookieNow = Get-ClearanceCookieValue -Socket $Socket -ProbeUrl $Config.Url
            if ($cookieNow -and $cookieNow -ne $cookieBefore) {
                Write-Host 'Challenge: cf_clearance baru terbit -> selesai.'
                return $true
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$probe.token)) {
                if (-not $tokenLogged) { Write-Host 'Challenge: token Turnstile terisi, tunggu submit...'; $tokenLogged = $true }
                continue
            }

            # Jaga tab tetap terlihat TANPA input sintetis.
            if (((Get-Date) - $lastFrontAt).TotalSeconds -ge 2) {
                # [void](Invoke-CdpCommand -Socket $Socket -Method 'Page.bringToFront')
                $lastFrontAt = Get-Date
            }

            # Warmup opsional, arah MENJAUH dari widget (di atasnya), bukan di atas iframe.
            if ($Config.WarmupEnabled -and ((Get-Date) - $lastWarmupAt).TotalSeconds -ge 1.5) {
                # $widget = $null
                # if (Get-Command Get-TurnstileWidgetState -ErrorAction SilentlyContinue) {
                #     $widget = Get-TurnstileWidgetState -Socket $Socket
                # }
                # $tx = 480 + (Get-Random -Minimum -60 -Maximum 60)
                # $ty = 120 + (Get-Random -Minimum -30 -Maximum 30)
                # if ($widget) {
                #     $tx = $widget.FrameX + $widget.FrameW / 2
                #     $ty = [Math]::Max(40, $widget.FrameY - 120)
                # }
                # Invoke-ChallengeMouseWarmup -Socket $Socket -X $tx -Y $ty
                $origin = Get-ViewportScreenOrigin
                if ($origin) {
                    Set-EdgeForeground
                    $cssX = 480 + (Get-Random -Minimum -60 -Maximum 60)
                    $cssY = 120 + (Get-Random -Minimum -30 -Maximum 30)
                    Send-RealMousePath -ToX [int]($origin.X + $cssX * $origin.Scale) -ToY [int]($origin.Y + $cssY * $origin.Scale)
                }
                $lastWarmupAt = Get-Date
            }

            if ($Config.AutoClickEnabled) {
                $widget = $null
                if (Get-Command Get-TurnstileWidgetState -ErrorAction SilentlyContinue) {
                    $widget = Get-TurnstileWidgetState -Socket $Socket
                }
                $clickX = $null; $clickY = $null; $clickSource = ''
                if ($widget -and $widget.HasCheckbox) {
                    $clickX = $widget.ClickX; $clickY = $widget.ClickY; $clickSource = $widget.Source
                }
                elseif ($probe.click -and [string]$probe.click.source -eq 'checkbox') {
                    $clickX = [double]$probe.click.x; $clickY = [double]$probe.click.y; $clickSource = 'checkbox'
                }
                if ($null -ne $clickX -and $clickCount -lt $Config.MaxClickTotal -and
                    ((Get-Date) - $lastClickAt).TotalSeconds -ge $Config.ClickGapSeconds) {
                    Invoke-TrustedMouseClick -Socket $Socket -X ($clickX + (Get-Random -Minimum -2 -Maximum 3)) -Y ($clickY + (Get-Random -Minimum -2 -Maximum 3))
                    $clickCount++
                    $lastClickAt = Get-Date
                    Write-Host ("Challenge: left-click ({0}) ke-{1}" -f $clickSource, $clickCount)
                }
            }
            continue
        }

        if ($sawChallenge) {
            # h1 hilang setelah verifikasi -> selesai (TANPA syarat htmlLength).
            if ([string]$probe.readyState -ne 'complete') { continue }
            $cleanStreak++
            if ($cleanStreak -ge 2) {
                Write-Host "Challenge: h1 'One more step' hilang (h1='$h1') -> selesai."
                return $true
            }
            continue
        }

        if ([string]$probe.readyState -eq 'complete') {
            if (Get-ClearanceCookieValue -Socket $Socket -ProbeUrl $Config.Url) {
                Write-Host 'Challenge: halaman normal & clearance ada -> sudah terverifikasi.'
                return $true
            }
            $cleanStreak++
            if ($cleanStreak -ge 3) { $loadDeadline = [datetime]::MinValue }
        }
    }
    return $false
}

function Resolve-CloudflareChallenge {
    param([int64]$DetectedAt = 0)
    $cfg = Get-ChallengeConfig
    if (-not $cfg.Enabled -or -not $script:BrowserPort) { return $false }
    if ($DetectedAt -le 0) { $DetectedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
    $state = Read-ChallengeState
    if ($state.solvedAt -gt $DetectedAt) {
        Write-Host 'Challenge: sudah diselesaikan worker lain, skip.'
        return $true
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($state.failedAt -gt 0 -and ($now - $state.failedAt) -lt $cfg.CooldownSeconds) { return $false }

    # Non-blocking: kalau sedang diverifikasi proses lain, langsung skip.
    $lock = Enter-ChallengeLock -WaitSeconds 0 -StaleSeconds ($cfg.SolveTimeout + 120)
    if (-not $lock) {
        $lockInfo = Get-ChallengeLockInfo
        $ownerPid = if ($lockInfo -and $lockInfo.pid) { [int]$lockInfo.pid } else { 0 }
        if ($ownerPid -gt 0) {
            Write-Host "Challenge: sedang diverifikasi PID $ownerPid -> skip, retry nanti."
        }
        return $false
    }

    $session = $null
    try {
        $state = Read-ChallengeState
        if ($state.solvedAt -gt $DetectedAt) { Write-Host 'Challenge: keburu beres dari worker lain.'; return $true }
        $session = New-ChallengeTabSession
        $ok = Invoke-CloudflareChallengeLoop -Socket $session.Socket -Config $cfg
        $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($ok) {
            Write-ChallengeState -SolvedAt $stamp -FailedAt 0
            Write-Host 'Challenge: beres, lanjut download.'
        }
        else {
            Write-ChallengeState -FailedAt $stamp
            Write-Warning "Challenge: belum lolos. Bisa centang manual di tab yang disorot: $($cfg.Url)"
        }
        return $ok
    }
    catch { Write-Warning "Challenge solver error: $($_.Exception.Message)"; return $false }
    finally {
        if ($session -and $session.Socket) { $session.Socket.Dispose() }
        Exit-ChallengeLock -Stream $lock
        Reset-NetworkState
    }
}
# ================== AKHIR CLOUDFLARE CHALLENGE SOLVER ==================

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

function New-BlueprintPageSession {
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

function Close-BlueprintPageSession {
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

function Save-BlueprintPageAsMhtmlInSession {
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

            $data = Wait-BlueprintPageReady -Socket $Socket -PageUrl $PageUrl -Attempt $attempt
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

function Save-BlueprintPageAsMhtml {
    param(
        [string]$PageUrl,
        [string]$Folder,
        [string]$FileBaseName = ''
    )

    $session = $null
    try {
        $session = New-BlueprintPageSession
        return Save-BlueprintPageAsMhtmlInSession -Socket $session.Socket -PageUrl $PageUrl -Folder $Folder -FileBaseName $FileBaseName
    }
    finally {
        Close-BlueprintPageSession -Session $session
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
        $session = New-BlueprintPageSession
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
                    Close-BlueprintPageSession -Session $session
                    $session = New-BlueprintPageSession
                }

                $workerResult = Save-BlueprintPageAsMhtmlInSession -Socket $session.Socket -PageUrl $pageUrl -Folder ([System.IO.Path]::GetFullPath([string]$task.SaveFolder)) -FileBaseName ([string]$task.FileBaseName)
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
        Close-BlueprintPageSession -Session $session
    }
}

if ($WorkerMode) {
    if (-not [string]::IsNullOrWhiteSpace($WorkerIpcDir)) {
        Invoke-PersistentPageWorker -Id $WorkerId -Directory $WorkerIpcDir
        return
    }

    try {
        $workerResult = Save-BlueprintPageAsMhtml -PageUrl $WorkerPageUrl -Folder ([System.IO.Path]::GetFullPath($WorkerSaveFolder))
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
            $result = Get-BlueprintDataFromMhtml -MhtmlPath $file.FullName -BaseUrl $sourceUrl -FallbackTitle $fallbackTitle
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

    $result = Get-BlueprintDataFromMhtml -MhtmlPath $entry.FilePath -BaseUrl $entry.Url -FallbackTitle $entry.Title -FallbackParentUrl $entry.ParentUrl
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
            [float]$PageIdleSeconds,
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
            $result = Save-BlueprintPageAsMhtml -PageUrl $task.Url -Folder $task.SaveFolder -FileBaseName ([string]$task.FileBaseName)
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

    $workerIpcDir = Join-Path $MhtmlRoot (".bp-workers-$PID-{0}" -f (Get-Date -Format 'yyyyMMddHHmmss'))
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
