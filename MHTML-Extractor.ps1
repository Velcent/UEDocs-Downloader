[CmdletBinding()]
param(
    [string]$InputPath = '',
    [string]$AssetsRoot = '',
    [string]$StrippedMhtmlRoot = '',
    [string]$TsvPath = '',
    [int]$ImageDownloadAttempts = 100000,
    [int]$BrowserReadyTimeoutSeconds = 60,
    [int]$FileParallelism = 1,
    [int]$AssetParallelism = 1,
    [switch]$OverwriteExistingOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Latin1 = [System.Text.Encoding]::GetEncoding(28591)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ProgressPreference = 'SilentlyContinue'
$ImageDownloadAttempts = [Math]::Max(1, $ImageDownloadAttempts)
$BrowserReadyTimeoutSeconds = [Math]::Max(5, $BrowserReadyTimeoutSeconds)
$FileParallelism = [Math]::Max(1, $FileParallelism)
$AssetParallelism = [Math]::Max(1, $AssetParallelism)
$script:BrowserPort = $null
$script:BrowserProcessId = $null
$script:CdpCommandId = 0

if (-not $InputPath) {
    $InputPath = Join-Path $PSScriptRoot 'mhtml'
}

if (-not $AssetsRoot) {
    $AssetsRoot = Join-Path $PSScriptRoot 'assets'
}

if (-not $StrippedMhtmlRoot) {
    $StrippedMhtmlRoot = Join-Path $AssetsRoot 'mhtml'
}

if (-not $TsvPath) {
    $TsvPath = Join-Path $AssetsRoot 'mhtml-uuid.tsv'
}

$BinRoot = Join-Path $AssetsRoot 'bin'
$AssetsVideoRoot = Join-Path $AssetsRoot 'video'
$VideoMp4Root = Join-Path $PSScriptRoot 'video\mp4'
$ScriptRootFull = [System.IO.Path]::GetFullPath($PSScriptRoot)
$script:BrowserProfileDir = Join-Path $AssetsRoot '.edge-profile'

function ConvertTo-TsvValue {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ''
    }

    return (($Value -replace "`t", ' ') -replace "(`r`n|`r|`n)", ' ').Trim()
}

function Test-ObjectProperty {
    param(
        [AllowNull()]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }

    return @($Object.PSObject.Properties.Match($Name)).Count -gt 0
}

function Get-RelativeAssetPath {
    param([string]$Uuid)

    return "assets/bin/$Uuid.bin"
}

function ConvertTo-FullPath {
    param([string]$RelativePath)

    return Join-Path $ScriptRootFull ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
}

function New-UuidV7 {
    $bytes = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }

    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    for ($i = 5; $i -ge 0; $i--) {
        $bytes[$i] = [byte]($timestamp -band 0xff)
        $timestamp = [Int64][Math]::Floor($timestamp / 256)
    }

    $bytes[6] = [byte](($bytes[6] -band 0x0f) -bor 0x70)
    $bytes[8] = [byte](($bytes[8] -band 0x3f) -bor 0x80)

    $hex = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    return '{0}-{1}-{2}-{3}-{4}' -f `
        $hex.Substring(0, 8),
        $hex.Substring(8, 4),
        $hex.Substring(12, 4),
        $hex.Substring(16, 4),
        $hex.Substring(20, 12)
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes, 0, $Bytes.Length))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-UnfoldedHeaderValue {
    param(
        [hashtable]$Headers,
        [string]$Name,
        [switch]$Url
    )

    $key = $Name.ToLowerInvariant()
    if (-not $Headers.ContainsKey($key)) {
        return ''
    }

    if ($Url) {
        $value = [regex]::Replace([string]$Headers[$key], "\r?\n[ \t]+", '')
        return [System.Net.WebUtility]::HtmlDecode($value.Trim())
    }

    return ([regex]::Replace([string]$Headers[$key], "\r?\n[ \t]+", ' ')).Trim()
}

function Read-MimeHeaders {
    param([string]$HeaderText)

    $headers = @{}
    $lastName = $null
    foreach ($line in [regex]::Split($HeaderText, "\r?\n")) {
        if ($line -match '^[ \t]' -and $lastName) {
            $headers[$lastName] = [string]$headers[$lastName] + "`r`n" + $line
            continue
        }

        $match = [regex]::Match($line, '^(?<name>[^:]+):\s*(?<value>.*)$')
        if ($match.Success) {
            $lastName = $match.Groups['name'].Value.Trim().ToLowerInvariant()
            $headers[$lastName] = $match.Groups['value'].Value
        }
    }

    return $headers
}

function Update-OrAddHeader {
    param(
        [string]$HeaderText,
        [string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $HeaderText
    }

    $pattern = '(?im)^' + [regex]::Escape($Name) + ':\s*[^\r\n]*(?:\r?\n[ \t][^\r\n]*)*'
    $replacement = "${Name}: $Value"
    if ([regex]::IsMatch($HeaderText, $pattern)) {
        return [regex]::Replace($HeaderText, $pattern, $replacement, 1)
    }

    return $HeaderText.TrimEnd("`r", "`n") + "`r`n" + $replacement
}

function Get-MimeBoundary {
    param([string]$ContentType)

    $match = [regex]::Match($ContentType, '(?i)(?:^|;)\s*boundary=(?:"(?<quoted>[^"]+)"|(?<plain>[^;\s]+))')
    if ($match.Success) {
        if ($match.Groups['quoted'].Success) {
            return $match.Groups['quoted'].Value
        }

        return $match.Groups['plain'].Value
    }

    return ''
}

function Get-InitialHeaderText {
    param([string]$Text)

    $separator = [regex]::Match($Text, "\r?\n\r?\n")
    if (-not $separator.Success) {
        return $Text
    }

    return $Text.Substring(0, $separator.Index)
}

function Get-MhtmlParts {
    param(
        [string]$Text,
        [string]$Boundary
    )

    $pattern = '(?m)^--' + [regex]::Escape($Boundary) + '(?<closing>--)?[ \t]*\r?$'
    $boundaryMatches = [regex]::Matches($Text, $pattern)
    if ($boundaryMatches.Count -lt 2) {
        return @()
    }

    $parts = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt ($boundaryMatches.Count - 1); $i++) {
        if ($boundaryMatches[$i].Groups['closing'].Success) {
            break
        }

        $start = $boundaryMatches[$i].Index + $boundaryMatches[$i].Length
        if ($start + 1 -lt $Text.Length -and $Text.Substring($start, 2) -eq "`r`n") {
            $start += 2
        }
        elseif ($start -lt $Text.Length -and $Text[$start] -eq "`n") {
            $start += 1
        }

        $end = $boundaryMatches[($i + 1)].Index
        $length = $end - $start
        if ($length -lt 0) {
            continue
        }

        $segment = $Text.Substring($start, $length)
        $separator = [regex]::Match($segment, "\r?\n\r?\n")
        if (-not $separator.Success) {
            continue
        }

        $headerText = $segment.Substring(0, $separator.Index)
        $bodyText = $segment.Substring($separator.Index + $separator.Length)
        if ($bodyText.EndsWith("`r`n")) {
            $bodyText = $bodyText.Substring(0, $bodyText.Length - 2)
        }
        elseif ($bodyText.EndsWith("`n")) {
            $bodyText = $bodyText.Substring(0, $bodyText.Length - 1)
        }

        $headers = Read-MimeHeaders -HeaderText $headerText

        $parts.Add([pscustomobject]@{
            Headers = $headers
            Body = $bodyText
        }) | Out-Null
    }

    return $parts
}

function Clear-MhtmlExternalPartBodies {
    param(
        [string]$Text,
        [string]$Boundary,
        [string]$SnapshotLocation,
        [System.Collections.Generic.Dictionary[string,object]]$UrlRows,
        [object[]]$AdditionalParts = @()
    )

    $pattern = '(?m)^--' + [regex]::Escape($Boundary) + '(?<closing>--)?[ \t]*\r?$'
    $boundaryMatches = [regex]::Matches($Text, $pattern)
    if ($boundaryMatches.Count -lt 2) {
        return [pscustomobject]@{
            Text = $Text
            Cleared = 0
        }
    }

    $builder = New-Object System.Text.StringBuilder
    $builder.Append($Text.Substring(0, $boundaryMatches[0].Index)) | Out-Null
    $cleared = 0

    for ($i = 0; $i -lt ($boundaryMatches.Count - 1); $i++) {
        $current = $boundaryMatches[$i]
        $next = $boundaryMatches[($i + 1)]
        $builder.Append($current.Value) | Out-Null

        $start = $current.Index + $current.Length
        if ($start + 1 -lt $Text.Length -and $Text.Substring($start, 2) -eq "`r`n") {
            $builder.Append("`r`n") | Out-Null
            $start += 2
        }
        elseif ($start -lt $Text.Length -and $Text[$start] -eq "`n") {
            $builder.Append("`n") | Out-Null
            $start += 1
        }

        $segment = $Text.Substring($start, $next.Index - $start)
        $separator = [regex]::Match($segment, "\r?\n\r?\n")
        if (-not $separator.Success) {
            $builder.Append($segment) | Out-Null
            continue
        }

        $headerText = $segment.Substring(0, $separator.Index)
        $headers = Read-MimeHeaders -HeaderText $headerText
        $location = Get-UnfoldedHeaderValue -Headers $headers -Name 'Content-Location' -Url
        $canClear = (
            $location -and
            [regex]::IsMatch($location, '^https://') -and
            (-not $SnapshotLocation -or $location -ne $SnapshotLocation) -and
            $UrlRows.ContainsKey($location)
        )

        if ($canClear) {
            $row = $UrlRows[$location]
            $normalizedEncoding = ''
            if ($row -and (Test-ObjectProperty -Object $row -Name 'encoding')) {
                $normalizedEncoding = Normalize-StoredEncoding -Encoding ([string]$row.encoding)
            }
            if (-not $normalizedEncoding) {
                $normalizedEncoding = '8bit'
            }

            $updatedHeaderText = Update-OrAddHeader -HeaderText $headerText -Name 'Content-Transfer-Encoding' -Value $normalizedEncoding
            $builder.Append($updatedHeaderText) | Out-Null
            $builder.Append($separator.Value) | Out-Null
            $cleared++
        }
        else {
            $builder.Append($segment) | Out-Null
        }
    }

    $added = 0
    foreach ($part in @($AdditionalParts)) {
        if (-not $part -or -not $part.link) {
            continue
        }

        $contentType = if ($part.content_type) { [string]$part.content_type } else { 'application/octet-stream' }
        $encoding = if ($part.encoding) { [string]$part.encoding } else { 'base64' }
        $builder.Append("--$Boundary`r`n") | Out-Null
        $builder.Append("Content-Type: $contentType`r`n") | Out-Null
        $builder.Append("Content-Transfer-Encoding: $encoding`r`n") | Out-Null
        $builder.Append("Content-Location: $($part.link)`r`n") | Out-Null
        $builder.Append("`r`n") | Out-Null
        $added++
    }

    $last = $boundaryMatches[($boundaryMatches.Count - 1)]
    $builder.Append($Text.Substring($last.Index)) | Out-Null

    return [pscustomobject]@{
        Text = $builder.ToString()
        Cleared = $cleared
        Added = $added
    }
}

function Decode-QuotedPrintable {
    param([string]$Text)

    $output = New-Object System.IO.MemoryStream
    try {
        for ($i = 0; $i -lt $Text.Length; $i++) {
            $ch = $Text[$i]
            if ($ch -eq '=') {
                if ($i + 2 -lt $Text.Length -and $Text[$i + 1] -eq "`r" -and $Text[$i + 2] -eq "`n") {
                    $i += 2
                    continue
                }

                if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "`n") {
                    $i += 1
                    continue
                }

                if ($i + 2 -lt $Text.Length) {
                    $hex = $Text.Substring($i + 1, 2)
                    if ($hex -match '^[0-9A-Fa-f]{2}$') {
                        $output.WriteByte([Convert]::ToByte($hex, 16))
                        $i += 2
                        continue
                    }
                }
            }

            $output.WriteByte([byte][char]$ch)
        }

        return $output.ToArray()
    }
    finally {
        $output.Dispose()
    }
}

function Decode-MimeBody {
    param(
        [string]$Body,
        [string]$Encoding
    )

    switch ($Encoding.ToLowerInvariant()) {
        'base64' {
            $base64 = [regex]::Replace($Body, '\s+', '')
            return [Convert]::FromBase64String($base64)
        }
        'quoted-printable' {
            return Decode-QuotedPrintable -Text $Body
        }
        default {
            return $Latin1.GetBytes($Body)
        }
    }
}

function Get-ContentTypeFromBytesOrUrl {
    param(
        [byte[]]$Bytes,
        [string]$Url,
        [string]$ResponseContentType = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($ResponseContentType)) {
        return (($ResponseContentType -split ';', 2)[0]).Trim()
    }

    if ($Bytes -and $Bytes.Length -ge 12) {
        if ($Bytes[0] -eq 0x89 -and $Bytes[1] -eq 0x50 -and $Bytes[2] -eq 0x4e -and $Bytes[3] -eq 0x47) { return 'image/png' }
        if ($Bytes[0] -eq 0xff -and $Bytes[1] -eq 0xd8 -and $Bytes[2] -eq 0xff) { return 'image/jpeg' }
        if ($Bytes[0] -eq 0x47 -and $Bytes[1] -eq 0x49 -and $Bytes[2] -eq 0x46) { return 'image/gif' }
        if ($Bytes[0] -eq 0x52 -and $Bytes[1] -eq 0x49 -and $Bytes[2] -eq 0x46 -and $Bytes[3] -eq 0x46 -and $Bytes[8] -eq 0x57 -and $Bytes[9] -eq 0x45 -and $Bytes[10] -eq 0x42 -and $Bytes[11] -eq 0x50) { return 'image/webp' }
        if ($Bytes[0] -eq 0x3c -and $Bytes[1] -eq 0x73 -and $Bytes[2] -eq 0x76 -and $Bytes[3] -eq 0x67) { return 'image/svg+xml' }
    }

    try {
        $path = ([Uri]$Url).AbsolutePath.ToLowerInvariant()
        switch -Regex ($path) {
            '\.png$' { return 'image/png' }
            '\.(jpg|jpeg)$' { return 'image/jpeg' }
            '\.gif$' { return 'image/gif' }
            '\.webp$' { return 'image/webp' }
            '\.svg$' { return 'image/svg+xml' }
            '\.avif$' { return 'image/avif' }
        }
    }
    catch {
    }

    return 'application/octet-stream'
}

function Get-LittleEndianUInt32 {
    param(
        [byte[]]$Bytes,
        [int]$Offset
    )

    if (-not $Bytes -or $Bytes.Length -lt ($Offset + 4)) {
        return -1
    }

    return [Int64](
        [UInt32]$Bytes[$Offset] -bor
        ([UInt32]$Bytes[$Offset + 1] -shl 8) -bor
        ([UInt32]$Bytes[$Offset + 2] -shl 16) -bor
        ([UInt32]$Bytes[$Offset + 3] -shl 24)
    )
}

function Test-ImageBytesComplete {
    param(
        [byte[]]$Bytes,
        [string]$ContentType,
        [string]$Url,
        [Int64]$ExpectedLength = -1
    )

    if (-not $Bytes -or $Bytes.Length -le 0) {
        return 'bytes kosong'
    }

    if ($ExpectedLength -gt 0 -and $Bytes.LongLength -ne $ExpectedLength) {
        return "panjang bytes tidak cocok Content-Length: $($Bytes.LongLength) != $ExpectedLength"
    }

    $type = Get-ContentTypeFromBytesOrUrl -Bytes $Bytes -Url $Url -ResponseContentType $ContentType
    switch -Regex ($type) {
        '^image/png$' {
            if ($Bytes.Length -lt 12) { return 'PNG terlalu kecil' }
            $n = $Bytes.Length
            if (-not (
                $Bytes[$n - 12] -eq 0x00 -and $Bytes[$n - 11] -eq 0x00 -and $Bytes[$n - 10] -eq 0x00 -and $Bytes[$n - 9] -eq 0x00 -and
                $Bytes[$n - 8] -eq 0x49 -and $Bytes[$n - 7] -eq 0x45 -and $Bytes[$n - 6] -eq 0x4e -and $Bytes[$n - 5] -eq 0x44
            )) {
                return 'PNG tidak punya chunk akhir IEND'
            }
        }
        '^image/jpeg$' {
            if ($Bytes.Length -lt 2 -or $Bytes[$Bytes.Length - 2] -ne 0xff -or $Bytes[$Bytes.Length - 1] -ne 0xd9) {
                return 'JPEG tidak punya marker akhir FFD9'
            }
        }
        '^image/gif$' {
            if ($Bytes[$Bytes.Length - 1] -ne 0x3b) {
                return 'GIF tidak punya trailer akhir'
            }
        }
        '^image/webp$' {
            if ($Bytes.Length -lt 12) { return 'WebP terlalu kecil' }
            $riffSize = Get-LittleEndianUInt32 -Bytes $Bytes -Offset 4
            if ($riffSize -ge 0 -and ($riffSize + 8) -ne $Bytes.Length) {
                return "WebP RIFF size tidak cocok: $($Bytes.Length) != $($riffSize + 8)"
            }
        }
    }

    return ''
}

function Get-PreferredManifestEncoding {
    param([string]$ContentType)

    if ($ContentType -match '(?i)(^image/svg\+xml\b|\+xml\b|^text/|javascript|json|css)') {
        return '8bit'
    }

    return 'base64'
}

function Normalize-StoredEncoding {
    param([string]$Encoding)

    if ([string]::IsNullOrWhiteSpace($Encoding)) {
        return ''
    }

    if ($Encoding.Trim().ToLowerInvariant() -eq 'quoted-printable') {
        return '8bit'
    }

    return $Encoding.Trim()
}

function Get-ContentTypeForManifestRow {
    param($Row)

    if (-not $Row -or -not $Row.path) {
        return 'application/octet-stream'
    }

    if ((Test-ObjectProperty -Object $Row -Name 'type') -and -not [string]::IsNullOrWhiteSpace([string]$Row.type)) {
        return [string]$Row.type
    }

    try {
        $fullPath = ConvertTo-FullPath -RelativePath ([string]$Row.path)
        if (Test-Path -LiteralPath $fullPath) {
            $bytes = [System.IO.File]::ReadAllBytes($fullPath)
            return Get-ContentTypeFromBytesOrUrl -Bytes $bytes -Url ([string]$Row.link)
        }
    }
    catch {
    }

    return Get-ContentTypeFromBytesOrUrl -Bytes ([byte[]]::new(0)) -Url ([string]$Row.link)
}

function Resolve-ExternalUrl {
    param(
        [string]$RawUrl,
        [string]$BaseUrl
    )

    if ([string]::IsNullOrWhiteSpace($RawUrl)) {
        return ''
    }

    $value = [System.Net.WebUtility]::HtmlDecode($RawUrl.Trim())
    if ($value -match '(?i)^(data|cid|blob|javascript|mailto):') {
        return ''
    }

    try {
        if ($value.StartsWith('//')) {
            $baseUri = [Uri]$BaseUrl
            return "$($baseUri.Scheme):$value"
        }

        if ([Uri]::IsWellFormedUriString($value, [UriKind]::Absolute)) {
            return ([Uri]$value).AbsoluteUri
        }

        if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
            return ([Uri]::new([Uri]$BaseUrl, $value)).AbsoluteUri
        }
    }
    catch {
    }

    return ''
}

function Resolve-AssetLink {
    param(
        [string]$RawUrl,
        [string]$BaseUrl,
        [switch]$AllowRelative
    )

    if ([string]::IsNullOrWhiteSpace($RawUrl)) {
        return ''
    }

    $value = [System.Net.WebUtility]::HtmlDecode($RawUrl.Trim())
    if ($value -match '(?i)^(data|cid|blob|javascript|mailto):') {
        return ''
    }

    try {
        if ($value.StartsWith('//')) {
            if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
                $baseUri = [Uri]$BaseUrl
                return "$($baseUri.Scheme):$value"
            }

            return "https:$value"
        }

        if ([Uri]::IsWellFormedUriString($value, [UriKind]::Absolute)) {
            return ([Uri]$value).AbsoluteUri
        }

        if ($AllowRelative) {
            return $value
        }

        if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
            return ([Uri]::new([Uri]$BaseUrl, $value)).AbsoluteUri
        }
    }
    catch {
    }

    return ''
}

function Get-HtmlBaseUrl {
    param(
        [string]$Html,
        [string]$FallbackUrl
    )

    $match = [regex]::Match($Html, '(?is)<base\b[^>]*\bhref\s*=\s*(?:"(?<dq>[^"]*)"|''(?<sq>[^'']*)''|(?<bare>[^\s>]+))')
    if ($match.Success) {
        foreach ($name in @('dq', 'sq', 'bare')) {
            if ($match.Groups[$name].Success) {
                $base = Resolve-ExternalUrl -RawUrl $match.Groups[$name].Value -BaseUrl $FallbackUrl
                if ($base) {
                    return $base
                }
            }
        }
    }

    return $FallbackUrl
}

function Get-ImgUrlsFromHtml {
    param(
        [string]$Html,
        [string]$BaseUrl
    )

    $urls = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.Dictionary[string,bool]'

    foreach ($img in [regex]::Matches($Html, '(?is)<img\b(?<attrs>[^>]*)>')) {
        $attrs = $img.Groups['attrs'].Value

        foreach ($attr in [regex]::Matches($attrs, '(?is)\bsrc\s*=\s*(?:"(?<dq>[^"]*)"|''(?<sq>[^'']*)''|(?<bare>[^\s>]+))')) {
            foreach ($name in @('dq', 'sq', 'bare')) {
                if ($attr.Groups[$name].Success) {
                    $url = Resolve-ExternalUrl -RawUrl $attr.Groups[$name].Value -BaseUrl $BaseUrl
                    if ($url -and $url -match '^https://' -and -not $seen.ContainsKey($url)) {
                        $seen[$url] = $true
                        $urls.Add($url) | Out-Null
                    }
                    break
                }
            }
        }

        foreach ($attr in [regex]::Matches($attrs, '(?is)\bsrcset\s*=\s*(?:"(?<dq>[^"]*)"|''(?<sq>[^'']*)''|(?<bare>[^\s>]+))')) {
            $srcset = ''
            foreach ($name in @('dq', 'sq', 'bare')) {
                if ($attr.Groups[$name].Success) {
                    $srcset = $attr.Groups[$name].Value
                    break
                }
            }

            foreach ($candidate in ($srcset -split ',')) {
                $raw = (($candidate.Trim() -split '\s+', 2)[0])
                $url = Resolve-ExternalUrl -RawUrl $raw -BaseUrl $BaseUrl
                if ($url -and $url -match '^https://' -and -not $seen.ContainsKey($url)) {
                    $seen[$url] = $true
                    $urls.Add($url) | Out-Null
                }
            }
        }
    }

    return @($urls)
}

function Add-AssetReference {
    param(
        $Results,
        $Seen,
        [string]$Link,
        [string]$FetchMode,
        [string]$ContentType = ''
    )

    if ([string]::IsNullOrWhiteSpace($Link) -or $Seen.ContainsKey($Link)) {
        return
    }

    $Seen[$Link] = $true
    $Results.Add([pscustomobject]@{
        link = $Link
        fetch_mode = $FetchMode
        content_type = $ContentType
    }) | Out-Null
}

function Get-HttpsBackgroundUrlsFromCss {
    param(
        [string]$CssText,
        [string]$BaseUrl
    )

    $urls = New-Object System.Collections.ArrayList
    $seen = @{}

    foreach ($declaration in [regex]::Matches($CssText, '(?is)\bbackground(?:-image)?\s*:\s*(?<value>[^;{}]+)')) {
        $value = $declaration.Groups['value'].Value
        foreach ($urlMatch in [regex]::Matches($value, '(?is)url\(\s*(?:"(?<dq>[^"]*)"|''(?<sq>[^'']*)''|(?<bare>[^)\s]+))\s*\)')) {
            foreach ($name in @('dq', 'sq', 'bare')) {
                if ($urlMatch.Groups[$name].Success) {
                    $url = Resolve-ExternalUrl -RawUrl $urlMatch.Groups[$name].Value -BaseUrl $BaseUrl
                    if ($url -and $url -match '^https://' -and -not $seen.ContainsKey($url)) {
                        $seen[$url] = $true
                        [void]$urls.Add($url)
                    }
                    break
                }
            }
        }
    }

    return [object[]]$urls
}

function Get-AssetReferencesFromHtml {
    param(
        [string]$Html,
        [string]$BaseUrl
    )

    $results = New-Object System.Collections.ArrayList
    $seen = @{}

    try {
        foreach ($imgUrl in Get-ImgUrlsFromHtml -Html $Html -BaseUrl $BaseUrl) {
            Add-AssetReference -Results $results -Seen $seen -Link $imgUrl -FetchMode 'browser'
        }
    }
    catch {
        throw "Get-AssetReferencesFromHtml/img: $($_.Exception.Message)"
    }

    try {
        foreach ($video in [regex]::Matches($Html, '(?is)<video\b(?<attrs>[^>]*)>')) {
            $attrs = $video.Groups['attrs'].Value

            foreach ($attr in [regex]::Matches($attrs, '(?is)\bsrc\s*=\s*(?:"(?<dq>[^"]*)"|''(?<sq>[^'']*)''|(?<bare>[^\s>]+))')) {
                foreach ($name in @('dq', 'sq', 'bare')) {
                    if ($attr.Groups[$name].Success) {
                        $link = Resolve-AssetLink -RawUrl $attr.Groups[$name].Value -BaseUrl $BaseUrl -AllowRelative
                        if ($link) {
                            Add-AssetReference -Results $results -Seen $seen -Link $link -FetchMode 'local-video' -ContentType 'video/mp4'
                        }
                        break
                    }
                }
            }

            foreach ($attr in [regex]::Matches($attrs, '(?is)\bposter\s*=\s*(?:"(?<dq>[^"]*)"|''(?<sq>[^'']*)''|(?<bare>[^\s>]+))')) {
                foreach ($name in @('dq', 'sq', 'bare')) {
                    if ($attr.Groups[$name].Success) {
                        $url = Resolve-ExternalUrl -RawUrl $attr.Groups[$name].Value -BaseUrl $BaseUrl
                        if ($url -and $url -match '^https://') {
                            Add-AssetReference -Results $results -Seen $seen -Link $url -FetchMode 'browser'
                        }
                        break
                    }
                }
            }
        }
    }
    catch {
        throw "Get-AssetReferencesFromHtml/video: $($_.Exception.Message)"
    }

    try {
        foreach ($videoBody in [regex]::Matches($Html, '(?is)<video\b[^>]*>(?<body>.*?)</video>')) {
            $body = $videoBody.Groups['body'].Value
            foreach ($source in [regex]::Matches($body, '(?is)<source\b(?<attrs>[^>]*)>')) {
                $attrs = $source.Groups['attrs'].Value
                foreach ($attr in [regex]::Matches($attrs, '(?is)\bsrc\s*=\s*(?:"(?<dq>[^"]*)"|''(?<sq>[^'']*)''|(?<bare>[^\s>]+))')) {
                    foreach ($name in @('dq', 'sq', 'bare')) {
                        if ($attr.Groups[$name].Success) {
                            $link = Resolve-AssetLink -RawUrl $attr.Groups[$name].Value -BaseUrl $BaseUrl -AllowRelative
                            if ($link) {
                                Add-AssetReference -Results $results -Seen $seen -Link $link -FetchMode 'local-video' -ContentType 'video/mp4'
                            }
                            break
                        }
                    }
                }
            }
        }
    }
    catch {
        throw "Get-AssetReferencesFromHtml/source: $($_.Exception.Message)"
    }

    try {
        foreach ($anchor in [regex]::Matches($Html, '(?is)<a\b(?<attrs>[^>]*)>')) {
            $attrs = $anchor.Groups['attrs'].Value
            $classMatch = [regex]::Match($attrs, '(?is)\bclass\s*=\s*(?:"(?<dq>[^"]*)"|''(?<sq>[^'']*)''|(?<bare>[^\s>]+))')
            $classValue = ''
            foreach ($name in @('dq', 'sq', 'bare')) {
                if ($classMatch.Success -and $classMatch.Groups[$name].Success) {
                    $classValue = $classMatch.Groups[$name].Value
                    break
                }
            }

            foreach ($attr in [regex]::Matches($attrs, '(?is)\bhref\s*=\s*(?:"(?<dq>[^"]*)"|''(?<sq>[^'']*)''|(?<bare>[^\s>]+))')) {
                foreach ($name in @('dq', 'sq', 'bare')) {
                    if ($attr.Groups[$name].Success) {
                        $link = Resolve-AssetLink -RawUrl $attr.Groups[$name].Value -BaseUrl $BaseUrl -AllowRelative
                        if (
                            $link -and
                            (
                                $classValue -match '(^|\s)video-link(\s|$)' -or
                                $link -match '(?i)^https://media\.local/(?:assets/video|video/mp4)/.+\.mp4(?:$|[?#])' -or
                                $link -match '(?i)(?:^|/)[^/]+\.mp4(?:$|[?#])'
                            )
                        ) {
                            Add-AssetReference -Results $results -Seen $seen -Link $link -FetchMode 'local-video' -ContentType 'video/mp4'
                        }
                        break
                    }
                }
            }
        }
    }
    catch {
        throw "Get-AssetReferencesFromHtml/anchor-video: $($_.Exception.Message)"
    }

    try {
        foreach ($styleBlock in [regex]::Matches($Html, '(?is)<style\b[^>]*>(?<css>.*?)</style>')) {
            foreach ($cssUrl in Get-HttpsBackgroundUrlsFromCss -CssText $styleBlock.Groups['css'].Value -BaseUrl $BaseUrl) {
                Add-AssetReference -Results $results -Seen $seen -Link $cssUrl -FetchMode 'browser'
            }
        }
    }
    catch {
        throw "Get-AssetReferencesFromHtml/style-block: $($_.Exception.Message)"
    }

    try {
        foreach ($styleAttr in [regex]::Matches($Html, '(?is)\bstyle\s*=\s*(?:"(?<dq>[^"]*)"|''(?<sq>[^'']*)'')')) {
            foreach ($name in @('dq', 'sq')) {
                if ($styleAttr.Groups[$name].Success) {
                    foreach ($cssUrl in Get-HttpsBackgroundUrlsFromCss -CssText $styleAttr.Groups[$name].Value -BaseUrl $BaseUrl) {
                        Add-AssetReference -Results $results -Seen $seen -Link $cssUrl -FetchMode 'browser'
                    }
                    break
                }
            }
        }
    }
    catch {
        throw "Get-AssetReferencesFromHtml/style-attr: $($_.Exception.Message)"
    }

    return [object[]]$results
}

function Get-MissingAssetRefsFromMhtml {
    param(
        [object[]]$Parts,
        [string]$SnapshotLocation,
        [System.Collections.Generic.Dictionary[string,bool]]$PartLocations
    )

    $missing = New-Object System.Collections.ArrayList
    $seen = @{}

    foreach ($part in @($Parts)) {
        $contentType = Get-UnfoldedHeaderValue -Headers $part.Headers -Name 'Content-Type'
        if ($contentType) {
            $contentType = (($contentType -split ';', 2)[0]).Trim()
        }

        if ($contentType -notmatch '(?i)^text/(html|css)\b' -or [string]::IsNullOrEmpty($part.Body)) {
            continue
        }

        $encoding = Get-UnfoldedHeaderValue -Headers $part.Headers -Name 'Content-Transfer-Encoding'
        if (-not $encoding) {
            $encoding = '7bit'
        }

        try {
            $bytes = Decode-MimeBody -Body $part.Body -Encoding $encoding
        }
        catch {
            continue
        }

        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        $location = Get-UnfoldedHeaderValue -Headers $part.Headers -Name 'Content-Location' -Url
        $refs = @()

        if ($contentType -match '(?i)^text/html\b') {
            $fallbackUrl = if ($location) { $location } else { $SnapshotLocation }
            $baseUrl = Get-HtmlBaseUrl -Html $text -FallbackUrl $fallbackUrl
            $refs = @(Get-AssetReferencesFromHtml -Html $text -BaseUrl $baseUrl)
        }
        elseif ($contentType -match '(?i)^text/css\b') {
            $baseUrl = if ($location) { $location } else { $SnapshotLocation }
            foreach ($cssUrl in Get-HttpsBackgroundUrlsFromCss -CssText $text -BaseUrl $baseUrl) {
                $refs += [pscustomobject]@{
                    link = $cssUrl
                    fetch_mode = 'browser'
                    content_type = ''
                }
            }
        }

        foreach ($ref in @($refs)) {
            if (-not $ref.link -or $PartLocations.ContainsKey([string]$ref.link) -or $seen.ContainsKey([string]$ref.link)) {
                continue
            }

            $seen[[string]$ref.link] = $true
            [void]$missing.Add($ref)
        }
    }

    return [object[]]$missing
}

function Resolve-LocalVideoFilePath {
    param(
        [string]$Link,
        [string]$VideoRoot
    )

    if ([string]::IsNullOrWhiteSpace($Link) -or -not (Test-Path -LiteralPath $VideoRoot)) {
        return ''
    }

    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.Dictionary[string,bool]'

    function Add-CandidateName {
        param([string]$Name)

        if ([string]::IsNullOrWhiteSpace($Name)) {
            return
        }

        $value = $Name.Trim()
        if ($seen.ContainsKey($value)) {
            return
        }

        $seen[$value] = $true
        $candidates.Add($value) | Out-Null
    }

    $decoded = [System.Net.WebUtility]::HtmlDecode($Link.Trim())
    $pathOnly = ($decoded -split '[?#]', 2)[0].Trim()

    try {
        if ([Uri]::IsWellFormedUriString($decoded, [UriKind]::Absolute)) {
            $uri = [Uri]$decoded
            Add-CandidateName -Name ([System.IO.Path]::GetFileName($uri.AbsolutePath))
            Add-CandidateName -Name ([System.IO.Path]::GetFileNameWithoutExtension($uri.AbsolutePath))
        }
    }
    catch {
    }

    Add-CandidateName -Name ([System.IO.Path]::GetFileName($pathOnly))
    Add-CandidateName -Name ([System.IO.Path]::GetFileNameWithoutExtension($pathOnly))

    foreach ($match in [regex]::Matches($decoded, '(?i)(?<token>[A-Za-z0-9_-]{6,})(?:\.mp4)?')) {
        Add-CandidateName -Name $match.Groups['token'].Value
    }

    foreach ($candidate in @($candidates)) {
        $testNames = New-Object 'System.Collections.Generic.List[string]'
        if ($candidate -match '(?i)\.mp4$') {
            $testNames.Add($candidate) | Out-Null
        }
        else {
            $testNames.Add("$candidate.mp4") | Out-Null
        }

        if ($candidate -notmatch '^(?i)V_' -and $candidate -notmatch '(?i)\.mp4$') {
            $testNames.Add("V_$candidate.mp4") | Out-Null
        }

        foreach ($testName in $testNames) {
            $fullPath = Join-Path $VideoRoot $testName
            if (Test-Path -LiteralPath $fullPath) {
                return $fullPath
            }
        }
    }

    return ''
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
        (Join-Path $AssetsRoot ".edge-profile-$PID-$(Get-Date -Format 'yyyyMMddHHmmss')")
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

        $process = Start-Process -FilePath $edgePath -ArgumentList $arguments -WindowStyle Hidden -PassThru

        try {
            Wait-DevTools -Port $script:BrowserPort
            $script:BrowserProfileDir = $profileDir
            $script:BrowserProcessId = $process.Id
            return
        }
        catch {
            Write-Warning $_.Exception.Message
            $script:BrowserPort = $null
            if ($process -and -not $process.HasExited) {
                try {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                }
                catch {
                }
            }
        }
    }

    throw 'Edge DevTools gagal dimulai.'
}

function Close-EdgeBrowser {
    if (-not $script:BrowserProcessId) {
        $script:BrowserPort = $null
        return
    }

    try {
        $toStop = New-Object System.Collections.Generic.List[int]
        $visited = New-Object 'System.Collections.Generic.Dictionary[int,bool]'
        $queue = New-Object System.Collections.Generic.Queue[int]
        $queue.Enqueue([int]$script:BrowserProcessId)

        while ($queue.Count -gt 0) {
            $currentId = $queue.Dequeue()
            if ($visited.ContainsKey($currentId)) {
                continue
            }

            $visited[$currentId] = $true
            $toStop.Add($currentId) | Out-Null

            foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $currentId" -ErrorAction SilentlyContinue)) {
                $queue.Enqueue([int]$child.ProcessId)
            }
        }

        foreach ($processId in ($toStop | Sort-Object -Descending)) {
            try {
                Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
            }
            catch {
            }
        }
    }
    finally {
        $script:BrowserProcessId = $null
        $script:BrowserPort = $null
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

    try {
        do {
            $segment = [ArraySegment[byte]]::new($buffer)
            $result = $Socket.ReceiveAsync($segment, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

            if ($result.Count -gt 0) {
                $stream.Write($buffer, 0, $result.Count)
            }
        } while (-not $result.EndOfMessage)

        return [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
    }
    finally {
        $stream.Dispose()
    }
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
        $responseId = if (Test-ObjectProperty -Object $response -Name 'id') { $response.id } else { $null }
    } while ($responseId -ne $id)

    if ((Test-ObjectProperty -Object $response -Name 'error') -and $response.error) {
        throw "$Method gagal: $($response.error.message)"
    }

    return $response
}

function Invoke-PageEval {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [string]$Expression
    )

    $response = Invoke-CdpCommand -Socket $Socket -Method 'Runtime.evaluate' -Params @{
        expression = $Expression
        awaitPromise = $true
        returnByValue = $true
    }

    if ((Test-ObjectProperty -Object $response.result -Name 'exceptionDetails') -and $response.result.exceptionDetails) {
        throw "Runtime.evaluate gagal: $($response.result.exceptionDetails.text)"
    }

    return $response.result.result.value
}

function New-AssetDownloadSession {
    $target = Open-DevToolsUrl -OpenUrl 'about:blank'
    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

    [void](Invoke-CdpCommand -Socket $socket -Method 'Page.enable')
    [void](Invoke-CdpCommand -Socket $socket -Method 'Runtime.enable')
    [void](Invoke-CdpCommand -Socket $socket -Method 'Network.enable')

    return [pscustomobject]@{
        Socket = $socket
        TargetId = [string]$target.id
        DownloadRoot = Join-Path $AssetsRoot ".edge-downloads-$PID"
    }
}

function Get-AssetSessionSocket {
    param($Session)

    foreach ($item in @($Session)) {
        if ($item -and (Test-ObjectProperty -Object $item -Name 'Socket')) {
            return $item.Socket
        }
    }

    return $null
}

function Get-AssetSessionTargetId {
    param($Session)

    foreach ($item in @($Session)) {
        if ($item -and (Test-ObjectProperty -Object $item -Name 'TargetId')) {
            return [string]$item.TargetId
        }
    }

    return ''
}

function Get-AssetSessionDownloadRoot {
    param($Session)

    foreach ($item in @($Session)) {
        if ($item -and (Test-ObjectProperty -Object $item -Name 'DownloadRoot')) {
            return [string]$item.DownloadRoot
        }
    }

    return (Join-Path $AssetsRoot ".edge-downloads-$PID")
}

function Close-AssetDownloadSession {
    param($Session)

    if (-not $Session) {
        return
    }

    try {
        $socket = Get-AssetSessionSocket -Session $Session
        if ($socket) {
            $socket.Dispose()
        }
    }
    catch {
    }

    Close-DevToolsPage -TargetId (Get-AssetSessionTargetId -Session $Session)
}

function Wait-BrowserPageComplete {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [string]$Url
    )

    $deadline = (Get-Date).AddSeconds($BrowserReadyTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $json = Invoke-PageEval -Socket $Socket -Expression @'
JSON.stringify({
    href: location.href,
    readyState: document.readyState,
    title: document.title,
    bodyText: document.body ? document.body.innerText : ''
})
'@
            $data = $json | ConvertFrom-Json
            if ($data.readyState -eq 'complete' -and [string]$data.href -ne 'about:blank') {
                return $data
            }
        }
        catch {
        }

        Start-Sleep -Milliseconds 250
    }

    throw "Timeout menunggu complete: $Url"
}

function ConvertTo-AssetDownloadResult {
    param(
        [byte[]]$Bytes,
        [string]$ContentType,
        [string]$FinalUrl,
        [Int64]$ExpectedLength,
        [string]$OriginalUrl
    )

    $validationError = Test-ImageBytesComplete -Bytes $Bytes -ContentType $ContentType -Url $OriginalUrl -ExpectedLength $ExpectedLength
    if (-not [string]::IsNullOrWhiteSpace($validationError)) {
        throw $validationError
    }

    return [pscustomobject]@{
        Bytes = $Bytes
        ContentType = $ContentType
        ContentLength = $ExpectedLength
        FinalUrl = $FinalUrl
    }
}

function Invoke-CdpCommandCollectEvents {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [string]$Method,
        [hashtable]$Params = @{},
        [scriptblock]$OnEvent,
        [int]$TimeoutSeconds = 30
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

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $responseText = Receive-WebSocketText $Socket
        $response = $responseText | ConvertFrom-Json
        $responseId = if (Test-ObjectProperty -Object $response -Name 'id') { $response.id } else { $null }
        if ($null -eq $responseId -and $OnEvent) {
            & $OnEvent $response
        }
    } while ($responseId -ne $id -and (Get-Date) -lt $deadline)

    if ($responseId -ne $id) {
        throw "$Method timeout."
    }

    if ((Test-ObjectProperty -Object $response -Name 'error') -and $response.error) {
        throw "$Method gagal: $($response.error.message)"
    }

    return $response
}

function Wait-NetworkRequestFinished {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [hashtable]$State,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($State.Finished -or $State.Failed) {
            return
        }

        $eventText = Receive-WebSocketText $Socket
        $event = $eventText | ConvertFrom-Json
        Update-NetworkAssetState -Event $event -State $State
    }
}

function Update-NetworkAssetState {
    param(
        $Event,
        [hashtable]$State
    )

    if (-not (Test-ObjectProperty -Object $Event -Name 'method') -or -not $Event.method) {
        return
    }

    if ([string]$Event.method -eq 'Network.requestWillBeSent') {
        $params = $Event.params
        $request = $params.request
        $requestUrl = if ($request -and (Test-ObjectProperty -Object $request -Name 'url')) { [string]$request.url } else { '' }
        if ($requestUrl -eq $State.Url -or (-not $State.RequestId -and (Test-ObjectProperty -Object $params -Name 'type') -and $params.type -eq 'Document')) {
            $State.RequestId = [string]$params.requestId
            $State.ResponseUrl = $requestUrl
        }
    }
    elseif ([string]$Event.method -eq 'Network.responseReceived') {
        $params = $Event.params
        $response = $params.response
        $responseUrl = if ($response -and (Test-ObjectProperty -Object $response -Name 'url')) { [string]$response.url } else { '' }
        if ($responseUrl -eq $State.Url -or (-not $State.RequestId -and (Test-ObjectProperty -Object $params -Name 'type') -and $params.type -eq 'Document')) {
            $State.RequestId = [string]$params.requestId
            $State.ResponseUrl = $responseUrl
            $State.ContentType = if ($response -and (Test-ObjectProperty -Object $response -Name 'mimeType')) { [string]$response.mimeType } else { '' }
            $State.ExpectedLength = -1
            if ($response -and (Test-ObjectProperty -Object $response -Name 'headers') -and $response.headers) {
                foreach ($property in $response.headers.PSObject.Properties) {
                    if ($property.Name -ieq 'content-length') {
                        $parsedLength = [Int64]-1
                        [Int64]::TryParse([string]$property.Value, [ref]$parsedLength) | Out-Null
                        $State.ExpectedLength = $parsedLength
                        break
                    }
                }
            }
        }
    }
    elseif ([string]$Event.method -eq 'Network.loadingFinished') {
        if ($State.RequestId -and [string]$Event.params.requestId -eq $State.RequestId) {
            $State.Finished = $true
        }
    }
    elseif ([string]$Event.method -eq 'Network.loadingFailed') {
        if ($State.RequestId -and [string]$Event.params.requestId -eq $State.RequestId) {
            $State.Failed = $true
            $State.ErrorText = if (Test-ObjectProperty -Object $Event.params -Name 'errorText') { [string]$Event.params.errorText } else { 'Network loading failed' }
        }
    }
}

function Get-AssetBytesFromNetworkBody {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [string]$Url,
        $NavigateResult,
        [hashtable]$State = $null
    )

    if (-not $State) {
        $State = [hashtable]::Synchronized(@{
            Url = $Url
            RequestId = ''
            ResponseUrl = ''
            ContentType = ''
            ExpectedLength = [Int64]-1
            Finished = $false
            Failed = $false
            ErrorText = ''
        })
    }

    Wait-NetworkRequestFinished -Socket $Socket -State $State -TimeoutSeconds $BrowserReadyTimeoutSeconds
    if ($State.Failed) {
        throw $State.ErrorText
    }

    if ([string]::IsNullOrWhiteSpace($State.RequestId) -and $NavigateResult -and (Test-ObjectProperty -Object $NavigateResult -Name 'result') -and (Test-ObjectProperty -Object $NavigateResult.result -Name 'loaderId')) {
        $State.RequestId = [string]$NavigateResult.result.loaderId
    }

    if ([string]::IsNullOrWhiteSpace($State.RequestId)) {
        throw "RequestId asset tidak ditemukan: $Url"
    }

    $bodyResponse = Invoke-CdpCommand -Socket $Socket -Method 'Network.getResponseBody' -Params @{ requestId = $State.RequestId }
    $body = [string]$bodyResponse.result.body
    if ([bool]$bodyResponse.result.base64Encoded) {
        $bytes = [Convert]::FromBase64String($body)
    }
    else {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    }

    $contentType = if (-not [string]::IsNullOrWhiteSpace($State.ContentType)) { [string]$State.ContentType } else { Get-ContentTypeFromBytesOrUrl -Bytes $bytes -Url $Url }
    $finalUrl = if (-not [string]::IsNullOrWhiteSpace($State.ResponseUrl)) { [string]$State.ResponseUrl } else { $Url }
    return (ConvertTo-AssetDownloadResult -Bytes $bytes -ContentType $contentType -FinalUrl $finalUrl -ExpectedLength ([Int64]$State.ExpectedLength) -OriginalUrl $Url)
}

function Set-EdgeDownloadBehavior {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [string]$DownloadPath
    )

    New-Item -ItemType Directory -Force -Path $DownloadPath | Out-Null
    $params = @{
        behavior = 'allow'
        downloadPath = $DownloadPath
        eventsEnabled = $true
    }

    try {
        [void](Invoke-CdpCommand -Socket $Socket -Method 'Browser.setDownloadBehavior' -Params $params)
        return
    }
    catch {
    }

    [void](Invoke-CdpCommand -Socket $Socket -Method 'Page.setDownloadBehavior' -Params @{
        behavior = 'allow'
        downloadPath = $DownloadPath
    })
}

function Wait-DownloadedAssetFile {
    param([string]$DownloadPath)

    $deadline = (Get-Date).AddSeconds($BrowserReadyTimeoutSeconds)
    $lastFile = $null
    $lastLength = -1
    $stableCount = 0
    $lastPartialFile = $null
    $lastPartialLength = -1
    $partialStableCount = 0

    while ((Get-Date) -lt $deadline) {
        $partialFiles = @(Get-ChildItem -LiteralPath $DownloadPath -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match '\.(crdownload|tmp)$'
        } | Sort-Object LastWriteTime -Descending)
        $files = @(Get-ChildItem -LiteralPath $DownloadPath -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -notmatch '\.(crdownload|tmp)$'
        } | Sort-Object LastWriteTime -Descending)

        if ($partialFiles.Count -gt 0) {
            $partialFile = $partialFiles[0]
            if ($lastPartialFile -and $lastPartialFile.FullName -eq $partialFile.FullName -and $lastPartialLength -eq $partialFile.Length) {
                $partialStableCount++
                if ($partialStableCount -ge 20) {
                    throw "Download temp macet/interrupted: $($partialFile.Name) ($($partialFile.Length) bytes)"
                }
            }
            else {
                $lastPartialFile = $partialFile
                $lastPartialLength = $partialFile.Length
                $partialStableCount = 0
            }
        }
        else {
            $lastPartialFile = $null
            $lastPartialLength = -1
            $partialStableCount = 0
        }

        if ($files.Count -gt 0 -and $partialFiles.Count -eq 0) {
            $file = $files[0]
            if ($lastFile -and $lastFile.FullName -eq $file.FullName -and $lastLength -eq $file.Length) {
                $stableCount++
                if ($stableCount -ge 2) {
                    return $file
                }
            }
            else {
                $lastFile = $file
                $lastLength = $file.Length
                $stableCount = 0
            }
        }

        Start-Sleep -Milliseconds 250
    }

    throw "Timeout menunggu download temp selesai."
}

function Remove-AssetDownloadTempDirectory {
    param(
        [string]$DownloadRoot,
        [string]$DownloadPath
    )

    try {
        $trimChars = [char[]]@('\', '/')
        $rootFull = [System.IO.Path]::GetFullPath($DownloadRoot).TrimEnd($trimChars) + [System.IO.Path]::DirectorySeparatorChar
        $pathFull = [System.IO.Path]::GetFullPath($DownloadPath).TrimEnd($trimChars) + [System.IO.Path]::DirectorySeparatorChar
        if ($pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $DownloadPath)) {
            Remove-Item -LiteralPath $DownloadPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
    }
}

function Get-AssetBytesWithDownloadFallback {
    param(
        $Session,
        [string]$Url,
        [string]$Referrer = ''
    )

    $socket = Get-AssetSessionSocket -Session $Session
    $downloadRoot = Get-AssetSessionDownloadRoot -Session $Session
    $downloadPath = Join-Path $downloadRoot ([guid]::NewGuid().ToString('n'))

    try {
        Set-EdgeDownloadBehavior -Socket $socket -DownloadPath $downloadPath

        $params = @{ url = $Url }
        if (-not [string]::IsNullOrWhiteSpace($Referrer)) {
            $params.referrer = $Referrer
        }
        $networkState = [hashtable]::Synchronized(@{
            Url = $Url
            RequestId = ''
            ResponseUrl = ''
            ContentType = ''
            ExpectedLength = [Int64]-1
            Finished = $false
            Failed = $false
            ErrorText = ''
        })
        $nav = Invoke-CdpCommandCollectEvents -Socket $socket -Method 'Page.navigate' -Params $params -TimeoutSeconds $BrowserReadyTimeoutSeconds -OnEvent {
            param($event)
            Update-NetworkAssetState -Event $event -State $networkState
        }

        $isDownload = $false
        if ((Test-ObjectProperty -Object $nav -Name 'result') -and (Test-ObjectProperty -Object $nav.result -Name 'isDownload')) {
            $isDownload = [bool]$nav.result.isDownload
        }

        if (-not $isDownload) {
            try {
                return (Get-AssetBytesFromNetworkBody -Socket $socket -Url $Url -NavigateResult $nav -State $networkState)
            }
            catch {
                $downloadedAfterRender = Wait-DownloadedAssetFile -DownloadPath $downloadPath
                if (-not $downloadedAfterRender) {
                    throw
                }

                $bytesAfterRender = [System.IO.File]::ReadAllBytes($downloadedAfterRender.FullName)
                $contentTypeAfterRender = Get-ContentTypeFromBytesOrUrl -Bytes $bytesAfterRender -Url $Url
                return (ConvertTo-AssetDownloadResult -Bytes $bytesAfterRender -ContentType $contentTypeAfterRender -FinalUrl $Url -ExpectedLength ([Int64]$bytesAfterRender.LongLength) -OriginalUrl $Url)
            }
        }

        $downloaded = Wait-DownloadedAssetFile -DownloadPath $downloadPath
        if (-not $downloaded) {
            throw "Download temp tidak muncul: $Url"
        }

        $bytes = [System.IO.File]::ReadAllBytes($downloaded.FullName)
        $contentType = Get-ContentTypeFromBytesOrUrl -Bytes $bytes -Url $Url
        return (ConvertTo-AssetDownloadResult -Bytes $bytes -ContentType $contentType -FinalUrl $Url -ExpectedLength ([Int64]$bytes.LongLength) -OriginalUrl $Url)
    }
    finally {
        Remove-AssetDownloadTempDirectory -DownloadRoot $downloadRoot -DownloadPath $downloadPath
    }
}

function Get-AssetBytesWithBrowser {
    param(
        $Session,
        [string]$Url,
        [string]$Referrer = ''
    )

    Write-Host "Ambil asset lewat Edge: $Url"
    $socket = Get-AssetSessionSocket -Session $Session
    if (-not $socket) {
        throw 'Session browser tidak punya socket aktif.'
    }

    $lastError = ''
    for ($attempt = 1; $attempt -le $ImageDownloadAttempts; $attempt++) {
        try {
            if ($socket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
                throw "Socket Edge tidak aktif: $($socket.State)"
            }

            if ($attempt -gt 1) {
                Write-Warning "Attempt asset sebelumnya gagal, coba ulang: $Url - $lastError"
            }

            return (Get-AssetBytesWithDownloadFallback -Session $Session -Url $Url -Referrer $Referrer)
        }
        catch {
            $lastError = $_.Exception.Message
            if ($socket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
                break
            }

            if ($attempt -ge $ImageDownloadAttempts) {
                break
            }
        }
    }

    throw "Download gagal setelah $ImageDownloadAttempts attempt: $Url ($lastError)"
}

function Get-InputMhtmlFiles {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "InputPath tidak ditemukan: $Path"
    }

    $item = Get-Item -LiteralPath $Path
    if (-not $item.PSIsContainer) {
        if ($item.Extension -ieq '.mhtml') {
            return @($item)
        }

        throw "InputPath bukan file .mhtml: $Path"
    }

    return @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Filter '*.mhtml')
}

function Get-RelativePathFromBase {
    param(
        [string]$BasePath,
        [string]$FullPath
    )

    $baseFull = [System.IO.Path]::GetFullPath($BasePath).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $targetFull = [System.IO.Path]::GetFullPath($FullPath)

    if ($targetFull.StartsWith($baseFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $targetFull.Substring($baseFull.Length + 1)
    }

    return [System.IO.Path]::GetFileName($FullPath)
}

function Import-ExistingHashMap {
    param([string]$ManifestPath)

    $map = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return $map
    }

    $rows = Import-Csv -LiteralPath $ManifestPath -Delimiter "`t"
    foreach ($row in $rows) {
        if (-not $row.sha256 -or -not $row.path) {
            continue
        }

        $fullPath = ConvertTo-FullPath -RelativePath $row.path
        if (-not (Test-Path -LiteralPath $fullPath)) {
            continue
        }

        $size = $null
        if ((Test-ObjectProperty -Object $row -Name 'size_bytes') -and $row.size_bytes) {
            $size = [Int64]$row.size_bytes
        }
        else {
            $size = (Get-Item -LiteralPath $fullPath).Length
        }

        $key = "$($row.sha256.ToLowerInvariant())`t$size"
        if (-not $map.ContainsKey($key)) {
            $map[$key] = $row.path
        }
    }

    return $map
}

function Import-ExistingUrlMap {
    param([string]$ManifestPath)

    $map = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return $map
    }

    $rows = Import-Csv -LiteralPath $ManifestPath -Delimiter "`t"
    foreach ($row in $rows) {
        if (-not $row.link -or -not $row.path) {
            continue
        }

        if (-not $map.ContainsKey($row.link)) {
            $map[$row.link] = [pscustomobject]@{
                link = $row.link
                path = $row.path
                type = if (Test-ObjectProperty -Object $row -Name 'type') { $row.type } else { '' }
                encoding = Normalize-StoredEncoding -Encoding ([string]$row.encoding)
                sha256 = $row.sha256
                size_bytes = $row.size_bytes
            }
        }
    }

    return $map
}

function Write-ManifestFile {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [string]$ManifestPath
    )

    $tsvLines = New-Object System.Collections.Generic.List[string]
    $tsvLines.Add("link`tpath`ttype`tencoding`tsha256`tsize_bytes") | Out-Null

    foreach ($row in ($Rows | Sort-Object link, path)) {
        $rowType = if ((Test-ObjectProperty -Object $row -Name 'type') -and -not [string]::IsNullOrWhiteSpace([string]$row.type)) {
            [string]$row.type
        }
        else {
            Get-ContentTypeForManifestRow -Row $row
        }

        $tsvLines.Add((
            (ConvertTo-TsvValue $row.link),
            (ConvertTo-TsvValue $row.path),
            (ConvertTo-TsvValue $rowType),
            (ConvertTo-TsvValue $row.encoding),
            (ConvertTo-TsvValue $row.sha256),
            (ConvertTo-TsvValue ([string]$row.size_bytes))
        ) -join "`t") | Out-Null
    }

    if (Test-Path -LiteralPath $ManifestPath) {
        $existingLines = [System.IO.File]::ReadAllLines($ManifestPath)
        $changed = $existingLines.Count -ne $tsvLines.Count
        if (-not $changed) {
            for ($i = 0; $i -lt $tsvLines.Count; $i++) {
                if ($existingLines[$i] -cne $tsvLines[$i]) {
                    $changed = $true
                    break
                }
            }
        }

        if (-not $changed) {
            return
        }

    }

    [System.IO.File]::WriteAllLines($ManifestPath, $tsvLines, $Utf8NoBom)
    Copy-Item -LiteralPath $ManifestPath -Destination ($ManifestPath + '.bak') -Force
}

function Save-ManifestCache {
    param(
        [System.Collections.Generic.Dictionary[string,object]]$UrlRows,
        [string]$ManifestPath
    )

    $manifestRows = New-Object System.Collections.Generic.List[object]
    foreach ($row in $UrlRows.Values) {
        $manifestRows.Add($row) | Out-Null
    }

    Write-ManifestFile -Rows $manifestRows -ManifestPath $ManifestPath
}

function Add-ManifestRow {
    param(
        [object]$Row,
        [System.Collections.Generic.Dictionary[string,object]]$UrlRows,
        [System.Collections.Generic.Dictionary[string,bool]]$SeenRows,
        [System.Collections.Generic.List[object]]$Rows,
        [string]$ManifestPath,
        [switch]$SaveNow
    )

    if (-not $Row -or -not (Test-ObjectProperty -Object $Row -Name 'link') -or [string]::IsNullOrWhiteSpace([string]$Row.link)) {
        return
    }

    $link = [string]$Row.link
    $UrlRows[$link] = $Row
    if (-not $SeenRows.ContainsKey($link)) {
        $SeenRows[$link] = $true
        $Rows.Add($Row) | Out-Null
    }

    if ($SaveNow) {
        Save-ManifestCache -UrlRows $UrlRows -ManifestPath $ManifestPath
    }
}

function Add-SharedStat {
    param(
        [hashtable]$Shared,
        [string]$Name,
        [Int64]$Amount = 1
    )

    [System.Threading.Monitor]::Enter($Shared.Lock)
    try {
        if (-not $Shared.Stats.Contains($Name)) {
            $Shared.Stats[$Name] = [Int64]0
        }

        $Shared.Stats[$Name] = [Int64]$Shared.Stats[$Name] + $Amount
    }
    finally {
        [System.Threading.Monitor]::Exit($Shared.Lock)
    }
}

function Get-OutputMhtmlPath {
    param(
        [System.IO.FileInfo]$File,
        [string]$InputBasePath,
        [string]$OutputRoot
    )

    $relativeMhtmlPath = Get-RelativePathFromBase -BasePath $InputBasePath -FullPath $File.FullName
    return (Join-Path $OutputRoot $relativeMhtmlPath)
}

function Get-ExistingManifestRowFromShared {
    param(
        [hashtable]$Shared,
        [string]$Link,
        [switch]$MarkSeen
    )

    if ([string]::IsNullOrWhiteSpace($Link)) {
        return $null
    }

    [System.Threading.Monitor]::Enter($Shared.Lock)
    try {
        if (-not $Shared.UrlToRow.ContainsKey($Link)) {
            return $null
        }

        $row = $Shared.UrlToRow[$Link]
        if ($MarkSeen) {
            Add-ManifestRow -Row $row -UrlRows $Shared.UrlToRow -SeenRows $Shared.SeenRows -Rows $Shared.Rows -ManifestPath $Shared.TsvPath
        }

        return $row
    }
    finally {
        [System.Threading.Monitor]::Exit($Shared.Lock)
    }
}

function Save-ManifestCacheFromShared {
    param([hashtable]$Shared)

    [System.Threading.Monitor]::Enter($Shared.Lock)
    try {
        Save-ManifestCache -UrlRows $Shared.UrlToRow -ManifestPath $Shared.TsvPath
    }
    finally {
        [System.Threading.Monitor]::Exit($Shared.Lock)
    }
}

function Register-AssetBytesInShared {
    param(
        [hashtable]$Shared,
        [string]$Link,
        [byte[]]$Bytes,
        [string]$ContentType,
        [string]$Encoding
    )

    $sha256 = Get-Sha256Hex -Bytes $Bytes
    $size = [Int64]$Bytes.LongLength
    $contentKey = "$sha256`t$size"

    [System.Threading.Monitor]::Enter($Shared.Lock)
    try {
        if ($Shared.UrlToRow.ContainsKey($Link)) {
            $row = $Shared.UrlToRow[$Link]
            Add-ManifestRow -Row $row -UrlRows $Shared.UrlToRow -SeenRows $Shared.SeenRows -Rows $Shared.Rows -ManifestPath $Shared.TsvPath
            $Shared.Stats.SkippedExistingUrls = [Int64]$Shared.Stats.SkippedExistingUrls + 1
            return $row
        }

        if ($Shared.HashToPath.ContainsKey($contentKey)) {
            $relativePath = $Shared.HashToPath[$contentKey]
            $Shared.Stats.ReusedFiles = [Int64]$Shared.Stats.ReusedFiles + 1
        }
        else {
            do {
                $uuid = New-UuidV7
                $relativePath = Get-RelativeAssetPath -Uuid $uuid
                $fullPath = ConvertTo-FullPath -RelativePath $relativePath
            } while (Test-Path -LiteralPath $fullPath)

            [System.IO.File]::WriteAllBytes($fullPath, $Bytes)
            $Shared.HashToPath[$contentKey] = $relativePath
            $Shared.Stats.WrittenFiles = [Int64]$Shared.Stats.WrittenFiles + 1
        }

        $row = [pscustomobject]@{
            link = $Link
            path = $relativePath
            type = $ContentType
            encoding = $Encoding
            sha256 = $sha256
            size_bytes = $size
        }
        Add-ManifestRow -Row $row -UrlRows $Shared.UrlToRow -SeenRows $Shared.SeenRows -Rows $Shared.Rows -ManifestPath $Shared.TsvPath -SaveNow
        return $row
    }
    finally {
        [System.Threading.Monitor]::Exit($Shared.Lock)
    }
}

function Get-AssetBytesWithSharedSlot {
    param(
        [hashtable]$Shared,
        [ref]$Session,
        [string]$Url,
        [string]$Referrer = ''
    )

    [void]$Shared.AssetSemaphore.Wait()
    try {
        $assetSocket = Get-AssetSessionSocket -Session $Session.Value
        if (-not $assetSocket -or $assetSocket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            if ($Session.Value) {
                Close-AssetDownloadSession -Session $Session.Value
            }
            $Session.Value = New-AssetDownloadSession
        }

        return (Get-AssetBytesWithBrowser -Session $Session.Value -Url $Url -Referrer $Referrer)
    }
    finally {
        [void]$Shared.AssetSemaphore.Release()
    }
}

function Clear-MhtmlWithSharedManifest {
    param(
        [hashtable]$Shared,
        [string]$Text,
        [string]$Boundary,
        [string]$SnapshotLocation,
        [object[]]$AdditionalParts
    )

    [System.Threading.Monitor]::Enter($Shared.Lock)
    try {
        return (Clear-MhtmlExternalPartBodies -Text $Text -Boundary $Boundary -SnapshotLocation $SnapshotLocation -UrlRows $Shared.UrlToRow -AdditionalParts $AdditionalParts)
    }
    finally {
        [System.Threading.Monitor]::Exit($Shared.Lock)
    }
}

function Process-MhtmlFile {
    param(
        [System.IO.FileInfo]$File,
        [string]$InputBasePath,
        [hashtable]$Shared,
        [switch]$OverwriteExistingOutput,
        $AssetSessionRef = $null
    )

    $outputMhtmlPath = Get-OutputMhtmlPath -File $File -InputBasePath $InputBasePath -OutputRoot $Shared.StrippedMhtmlRoot
    if (-not $OverwriteExistingOutput -and (Test-Path -LiteralPath $outputMhtmlPath)) {
        Add-SharedStat -Shared $Shared -Name 'SkippedExistingMhtml'
        return
    }

    Add-SharedStat -Shared $Shared -Name 'Files'
    Write-Host "Parsing $($File.FullName)"

    $assetSession = $null
    try {
        $text = [System.IO.File]::ReadAllText($File.FullName, $Latin1)
        $rootHeaders = Read-MimeHeaders -HeaderText (Get-InitialHeaderText -Text $text)
        $snapshotLocation = Get-UnfoldedHeaderValue -Headers $rootHeaders -Name 'Snapshot-Content-Location' -Url
        $contentType = Get-UnfoldedHeaderValue -Headers $rootHeaders -Name 'Content-Type'
        $boundary = Get-MimeBoundary -ContentType $contentType

        if (-not $boundary) {
            Write-Warning "Boundary tidak ditemukan: $($File.FullName)"
            return
        }

        $parts = @(Get-MhtmlParts -Text $text -Boundary $boundary)
        $filePartLocations = New-Object 'System.Collections.Generic.Dictionary[string,bool]'
        foreach ($part in $parts) {
            $location = Get-UnfoldedHeaderValue -Headers $part.Headers -Name 'Content-Location' -Url
            if ($location -and -not $filePartLocations.ContainsKey($location)) {
                $filePartLocations[$location] = $true
            }

            if (-not $location -or $location -notmatch '^https://') {
                Add-SharedStat -Shared $Shared -Name 'SkippedNonHttpsParts'
                continue
            }

            if ($snapshotLocation -and $location -eq $snapshotLocation) {
                Add-SharedStat -Shared $Shared -Name 'SkippedSnapshotParts'
                continue
            }

            $existingRow = Get-ExistingManifestRowFromShared -Shared $Shared -Link $location -MarkSeen
            if ($existingRow) {
                Add-SharedStat -Shared $Shared -Name 'SkippedExistingUrls'
                continue
            }

            $transferEncoding = Get-UnfoldedHeaderValue -Headers $part.Headers -Name 'Content-Transfer-Encoding'
            if (-not $transferEncoding) {
                $transferEncoding = '7bit'
            }
            $partContentType = Get-UnfoldedHeaderValue -Headers $part.Headers -Name 'Content-Type'
            if ($partContentType) {
                $partContentType = (($partContentType -split ';', 2)[0]).Trim()
            }
            if (-not $partContentType) {
                $partContentType = 'application/octet-stream'
            }
            $storedEncoding = Normalize-StoredEncoding -Encoding $transferEncoding
            if (-not $storedEncoding) {
                $storedEncoding = $transferEncoding
            }

            if ([string]::IsNullOrEmpty($part.Body)) {
                Write-Warning "Body kosong dan URL belum ada di manifest, skip: $location"
                continue
            }

            try {
                $bytes = Decode-MimeBody -Body $part.Body -Encoding $transferEncoding
            }
            catch {
                Write-Warning "Gagal decode $location ($transferEncoding) di $($File.Name): $($_.Exception.Message)"
                continue
            }

            if ($partContentType -match '(?i)^image/') {
                $validationError = Test-ImageBytesComplete -Bytes $bytes -ContentType $partContentType -Url $location
                if (-not [string]::IsNullOrWhiteSpace($validationError)) {
                    Add-SharedStat -Shared $Shared -Name 'InvalidLocalImageParts'
                    Write-Warning "Gambar multipart corrupt setelah decode, download ulang: $location - $validationError"
                    try {
                        $sessionRef = if ($AssetSessionRef) { $AssetSessionRef } else { [ref]$assetSession }
                        $download = Get-AssetBytesWithSharedSlot -Shared $Shared -Session $sessionRef -Url $location -Referrer $snapshotLocation
                        $bytes = [byte[]]$download.Bytes
                        $partContentType = Get-ContentTypeFromBytesOrUrl -Bytes $bytes -Url $location -ResponseContentType ([string]$download.ContentType)
                        $storedEncoding = Get-PreferredManifestEncoding -ContentType $partContentType
                        Add-SharedStat -Shared $Shared -Name 'DownloadedImgUrls'
                    }
                    catch {
                        Add-SharedStat -Shared $Shared -Name 'FailedImgUrls'
                        Write-Warning "Gagal download ulang gambar multipart corrupt: $location - $($_.Exception.Message)"
                        continue
                    }
                }
            }

            [void](Register-AssetBytesInShared -Shared $Shared -Link $location -Bytes $bytes -ContentType $partContentType -Encoding $storedEncoding)
            Add-SharedStat -Shared $Shared -Name 'ExtractedParts'
        }

        $missingImgParts = New-Object System.Collections.Generic.List[object]
        foreach ($assetRef in Get-MissingAssetRefsFromMhtml -Parts $parts -SnapshotLocation $snapshotLocation -PartLocations $filePartLocations) {
            $assetLink = [string]$assetRef.link
            if (-not $assetLink -or $filePartLocations.ContainsKey($assetLink)) {
                continue
            }

            Add-SharedStat -Shared $Shared -Name 'MissingImgUrls'
            $imgRow = $null
            $contentType = ''

            if ([string]$assetRef.fetch_mode -eq 'local-video') {
                $localVideoPath = Resolve-LocalVideoFilePath -Link $assetLink -VideoRoot $VideoMp4Root
                if (-not $localVideoPath) {
                    continue
                }

                try {
                    $targetName = [System.IO.Path]::GetFileName($localVideoPath)
                    $targetPath = Join-Path $AssetsVideoRoot $targetName
                    $shouldCopy = $true

                    if (Test-Path -LiteralPath $targetPath) {
                        $sourceInfo = Get-Item -LiteralPath $localVideoPath
                        $targetInfo = Get-Item -LiteralPath $targetPath
                        if ($sourceInfo.Length -eq $targetInfo.Length) {
                            $shouldCopy = $false
                        }
                    }

                    if ($shouldCopy) {
                        Copy-Item -LiteralPath $localVideoPath -Destination $targetPath -Force
                    }

                    Add-SharedStat -Shared $Shared -Name 'LinkedLocalVideoUrls'
                }
                catch {
                    Write-Warning "Gagal proses video lokal: $assetLink - $($_.Exception.Message)"
                    continue
                }
            }
            else {
                $imgRow = Get-ExistingManifestRowFromShared -Shared $Shared -Link $assetLink -MarkSeen
                if ($imgRow) {
                    $contentType = Get-ContentTypeForManifestRow -Row $imgRow
                    Add-SharedStat -Shared $Shared -Name 'SkippedExistingUrls'
                }
                else {
                    try {
                        $sessionRef = if ($AssetSessionRef) { $AssetSessionRef } else { [ref]$assetSession }
                        $download = Get-AssetBytesWithSharedSlot -Shared $Shared -Session $sessionRef -Url $assetLink -Referrer $snapshotLocation
                        $bytes = [byte[]]$download.Bytes
                        $contentType = Get-ContentTypeFromBytesOrUrl -Bytes $bytes -Url $assetLink -ResponseContentType ([string]$download.ContentType)
                        $manifestEncoding = Get-PreferredManifestEncoding -ContentType $contentType
                        $imgRow = Register-AssetBytesInShared -Shared $Shared -Link $assetLink -Bytes $bytes -ContentType $contentType -Encoding $manifestEncoding
                        Add-SharedStat -Shared $Shared -Name 'DownloadedImgUrls'
                    }
                    catch {
                        Add-SharedStat -Shared $Shared -Name 'FailedImgUrls'
                        Write-Warning "Gagal download asset tanpa multipart: $assetLink - $($_.Exception.Message)"
                        continue
                    }
                }
            }

            if ($imgRow) {
                $missingImgParts.Add([pscustomobject]@{
                    link = $assetLink
                    content_type = $contentType
                    encoding = if ($imgRow -and $imgRow.encoding) { Normalize-StoredEncoding -Encoding ([string]$imgRow.encoding) } else { Get-PreferredManifestEncoding -ContentType $contentType }
                }) | Out-Null
                $filePartLocations[$assetLink] = $true
            }
        }

        $clearedResult = Clear-MhtmlWithSharedManifest -Shared $Shared -Text $text -Boundary $boundary -SnapshotLocation $snapshotLocation -AdditionalParts ([object[]]$missingImgParts.ToArray())
        if ($clearedResult.Cleared -gt 0 -or $clearedResult.Added -gt 0) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputMhtmlPath) | Out-Null
            [System.IO.File]::WriteAllText($outputMhtmlPath, $clearedResult.Text, $Latin1)
            Add-SharedStat -Shared $Shared -Name 'ClearedPartBodies' -Amount ([Int64]$clearedResult.Cleared)
            Add-SharedStat -Shared $Shared -Name 'AddedMissingImgParts' -Amount ([Int64]$clearedResult.Added)
            Add-SharedStat -Shared $Shared -Name 'StrippedMhtmlFiles'
        }

        Save-ManifestCacheFromShared -Shared $Shared
    }
    finally {
        if (-not $AssetSessionRef) {
            Close-AssetDownloadSession -Session $assetSession
        }
    }
}

function Get-ScriptFunctionDefinitions {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        throw "Gagal parse script untuk worker parallel: $($parseErrors[0].Message)"
    }

    $functions = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)

    return (($functions | ForEach-Object { $_.Extent.Text }) -join "`r`n")
}

function Invoke-MhtmlFilesParallel {
    param(
        [System.IO.FileInfo[]]$Files,
        [string]$InputBasePath,
        [hashtable]$Shared,
        [int]$ThrottleLimit,
        [string]$FunctionDefinitions,
        [hashtable]$Context,
        [switch]$OverwriteExistingOutput
    )

    $pool = [runspacefactory]::CreateRunspacePool(1, $ThrottleLimit)
    $pool.ApartmentState = 'MTA'
    $pool.Open()
    $tasks = New-Object System.Collections.Generic.List[object]

    $workerScript = {
        param(
            [string]$Definitions,
            [string[]]$FilePaths,
            [string]$WorkerInputBasePath,
            [hashtable]$WorkerShared,
            [hashtable]$WorkerContext,
            [bool]$WorkerOverwriteExistingOutput
        )

        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'
        Invoke-Expression $Definitions

        $script:BrowserPort = if ($WorkerContext.BrowserPort) { [int]$WorkerContext.BrowserPort } else { $null }
        $script:BrowserProcessId = $null
        $script:CdpCommandId = 0
        $script:BrowserProfileDir = [string]$WorkerContext.BrowserProfileDir
        $script:BrowserReadyTimeoutSeconds = [int]$WorkerContext.BrowserReadyTimeoutSeconds

        $Latin1 = [System.Text.Encoding]::GetEncoding(28591)
        $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $ImageDownloadAttempts = [int]$WorkerContext.ImageDownloadAttempts
        $BrowserReadyTimeoutSeconds = [int]$WorkerContext.BrowserReadyTimeoutSeconds
        $AssetsRoot = [string]$WorkerContext.AssetsRoot
        $BinRoot = [string]$WorkerContext.BinRoot
        $AssetsVideoRoot = [string]$WorkerContext.AssetsVideoRoot
        $VideoMp4Root = [string]$WorkerContext.VideoMp4Root
        $ScriptRootFull = [string]$WorkerContext.ScriptRootFull

        $workerAssetSession = $null
        try {
            foreach ($filePath in $FilePaths) {
                $file = Get-Item -LiteralPath $filePath
                Process-MhtmlFile -File $file -InputBasePath $WorkerInputBasePath -Shared $WorkerShared -OverwriteExistingOutput:([bool]$WorkerOverwriteExistingOutput) -AssetSessionRef ([ref]$workerAssetSession)
            }
        }
        finally {
            Close-AssetDownloadSession -Session $workerAssetSession
        }

        return ($FilePaths -join "`n")
    }

    try {
        $workerCount = [Math]::Min($ThrottleLimit, $Files.Count)
        $chunks = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $workerCount; $i++) {
            $chunks.Add((New-Object 'System.Collections.Generic.List[string]')) | Out-Null
        }

        for ($i = 0; $i -lt $Files.Count; $i++) {
            $chunks[$i % $workerCount].Add($Files[$i].FullName) | Out-Null
        }

        foreach ($chunk in $chunks) {
            if ($chunk.Count -eq 0) {
                continue
            }

            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($workerScript)
            [void]$ps.AddArgument($FunctionDefinitions)
            [void]$ps.AddArgument([string[]]$chunk.ToArray())
            [void]$ps.AddArgument($InputBasePath)
            [void]$ps.AddArgument($Shared)
            [void]$ps.AddArgument($Context)
            [void]$ps.AddArgument([bool]$OverwriteExistingOutput)
            $tasks.Add([pscustomobject]@{
                PowerShell = $ps
                Handle = $ps.BeginInvoke()
                File = "$($chunk.Count) file(s)"
            }) | Out-Null
        }

        $errors = New-Object System.Collections.Generic.List[string]
        foreach ($task in $tasks) {
            try {
                [void]$task.PowerShell.EndInvoke($task.Handle)
            }
            catch {
                $errors.Add("$($task.File): $($_.Exception.Message)") | Out-Null
            }
        }

        if ($errors.Count -gt 0) {
            throw "Parallel worker gagal:`n$($errors -join "`n")"
        }
    }
    finally {
        foreach ($task in $tasks) {
            if ($task.PowerShell) {
                $task.PowerShell.Dispose()
            }
        }

        $pool.Close()
        $pool.Dispose()
    }
}

Write-Host "Menyiapkan folder output..."
New-Item -ItemType Directory -Force -Path $BinRoot | Out-Null
New-Item -ItemType Directory -Force -Path $AssetsVideoRoot | Out-Null
New-Item -ItemType Directory -Force -Path $StrippedMhtmlRoot | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $TsvPath) | Out-Null

Write-Host "Scan input MHTML: $InputPath"
$allFiles = @(Get-InputMhtmlFiles -Path $InputPath)
Write-Host "Input MHTML ditemukan: $($allFiles.Count)"
$inputItem = Get-Item -LiteralPath $InputPath
if ($inputItem.PSIsContainer) {
    $inputBasePath = $inputItem.FullName
}
else {
    $inputBasePath = $inputItem.DirectoryName
}

Write-Host "Load manifest hash map: $TsvPath"
$hashToPath = Import-ExistingHashMap -ManifestPath $TsvPath
Write-Host "Hash map siap        : $($hashToPath.Count) item"
Write-Host "Load manifest URL map : $TsvPath"
$urlToRow = Import-ExistingUrlMap -ManifestPath $TsvPath
Write-Host "URL map siap         : $($urlToRow.Count) item"
$rows = New-Object System.Collections.Generic.List[object]
$seenRows = New-Object 'System.Collections.Generic.Dictionary[string,bool]'
$stats = [ordered]@{
    InputMhtmlFiles = $allFiles.Count
    QueuedMhtmlFiles = 0
    Files = 0
    ExtractedParts = 0
    WrittenFiles = 0
    ReusedFiles = 0
    ClearedPartBodies = 0
    StrippedMhtmlFiles = 0
    SkippedExistingMhtml = 0
    MissingImgUrls = 0
    DownloadedImgUrls = 0
    FailedImgUrls = 0
    AddedMissingImgParts = 0
    LinkedLocalVideoUrls = 0
    InvalidLocalImageParts = 0
    SkippedExistingUrls = 0
    SkippedSnapshotParts = 0
    SkippedNonHttpsParts = 0
}

Write-Host "Cek output MHTML existing..."
$files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
foreach ($file in $allFiles) {
    $outputMhtmlPath = Get-OutputMhtmlPath -File $file -InputBasePath $inputBasePath -OutputRoot $StrippedMhtmlRoot
    if (-not $OverwriteExistingOutput -and (Test-Path -LiteralPath $outputMhtmlPath)) {
        $stats.SkippedExistingMhtml++
        continue
    }

    $files.Add($file) | Out-Null
}
$stats.QueuedMhtmlFiles = $files.Count

$shared = [hashtable]::Synchronized(@{
    Lock = [object]::new()
    AssetSemaphore = [System.Threading.SemaphoreSlim]::new($AssetParallelism, $AssetParallelism)
    Stats = $stats
    HashToPath = $hashToPath
    UrlToRow = $urlToRow
    Rows = $rows
    SeenRows = $seenRows
    TsvPath = $TsvPath
    StrippedMhtmlRoot = $StrippedMhtmlRoot
})

try {
    if (-not (Test-Path -LiteralPath $TsvPath)) {
        Save-ManifestCacheFromShared -Shared $shared
    }

    Write-Host "Input MHTML files    : $($stats.InputMhtmlFiles)"
    Write-Host "Existing output skip : $($stats.SkippedExistingMhtml)"
    Write-Host "Queued MHTML files   : $($stats.QueuedMhtmlFiles)"
    Write-Host "File parallelism     : $FileParallelism"
    Write-Host "Asset parallelism    : $AssetParallelism"

    if ($files.Count -gt 0) {
        if ($FileParallelism -le 1) {
            $singleAssetSession = $null
            try {
                foreach ($file in $files) {
                    Process-MhtmlFile -File $file -InputBasePath $inputBasePath -Shared $shared -OverwriteExistingOutput:$OverwriteExistingOutput -AssetSessionRef ([ref]$singleAssetSession)
                }
            }
            finally {
                Close-AssetDownloadSession -Session $singleAssetSession
            }
        }
        else {
            Write-Host "Menyiapkan Edge untuk worker parallel..."
            Ensure-Edge
            Write-Host "Menyiapkan runspace worker parallel..."
            $functionDefinitions = Get-ScriptFunctionDefinitions
            $context = @{
                AssetsRoot = $AssetsRoot
                BinRoot = $BinRoot
                AssetsVideoRoot = $AssetsVideoRoot
                VideoMp4Root = $VideoMp4Root
                ScriptRootFull = $ScriptRootFull
                BrowserPort = $script:BrowserPort
                BrowserProfileDir = $script:BrowserProfileDir
                ImageDownloadAttempts = $ImageDownloadAttempts
                BrowserReadyTimeoutSeconds = $BrowserReadyTimeoutSeconds
            }

            Invoke-MhtmlFilesParallel -Files ([System.IO.FileInfo[]]$files.ToArray()) -InputBasePath $inputBasePath -Shared $shared -ThrottleLimit $FileParallelism -FunctionDefinitions $functionDefinitions -Context $context -OverwriteExistingOutput:$OverwriteExistingOutput
        }
    }
}
finally {
    Close-EdgeBrowser
    Save-ManifestCacheFromShared -Shared $shared
    if ($shared.AssetSemaphore) {
        $shared.AssetSemaphore.Dispose()
    }
}

Write-Host ''
Write-Host "Done."
Write-Host "Input MHTML files    : $($stats.InputMhtmlFiles)"
Write-Host "Queued MHTML files   : $($stats.QueuedMhtmlFiles)"
Write-Host "Skipped output MHTML : $($stats.SkippedExistingMhtml)"
Write-Host "Files parsed          : $($stats.Files)"
Write-Host "Parts extracted      : $($stats.ExtractedParts)"
Write-Host "Files written        : $($stats.WrittenFiles)"
Write-Host "Files reused         : $($stats.ReusedFiles)"
Write-Host "Part bodies cleared  : $($stats.ClearedPartBodies)"
Write-Host "Stripped MHTML files : $($stats.StrippedMhtmlFiles)"
Write-Host "Missing asset refs   : $($stats.MissingImgUrls)"
Write-Host "Downloaded assets    : $($stats.DownloadedImgUrls)"
Write-Host "Linked local videos  : $($stats.LinkedLocalVideoUrls)"
Write-Host "Invalid local images : $($stats.InvalidLocalImageParts)"
Write-Host "Failed asset URLs    : $($stats.FailedImgUrls)"
Write-Host "Added asset parts    : $($stats.AddedMissingImgParts)"
Write-Host "Skipped existing URL : $($stats.SkippedExistingUrls)"
Write-Host "Skipped snapshot URL : $($stats.SkippedSnapshotParts)"
Write-Host "Skipped non-HTTPS    : $($stats.SkippedNonHttpsParts)"
Write-Host "Manifest             : $TsvPath"
Write-Host "Asset folder         : $BinRoot"
Write-Host "Video folder         : $AssetsVideoRoot"
Write-Host "Stripped MHTML folder: $StrippedMhtmlRoot"
pause
