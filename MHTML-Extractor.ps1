[CmdletBinding()]
param(
    [string]$InputPath = '',
    [string]$AssetsRoot = '',
    [string]$StrippedMhtmlRoot = '',
    [string]$TsvPath = '',
    [int]$ImageDownloadAttempts = 100000,
    [int]$BrowserReadyTimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Latin1 = [System.Text.Encoding]::GetEncoding(28591)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ProgressPreference = 'SilentlyContinue'
$ImageDownloadAttempts = [Math]::Max(1, $ImageDownloadAttempts)
$BrowserReadyTimeoutSeconds = [Math]::Max(5, $BrowserReadyTimeoutSeconds)
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

        foreach ($pid in ($toStop | Sort-Object -Descending)) {
            try {
                Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
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

function Get-AssetBytesWithBrowser {
    param(
        $Session,
        [string]$Url,
        [string]$Referrer = ''
    )

    Write-Host "Download img lewat Edge: $Url"
    $socket = Get-AssetSessionSocket -Session $Session
    if (-not $socket) {
        throw 'Session browser tidak punya socket aktif.'
    }

    $lastError = ''
    for ($attempt = 1; $attempt -le $ImageDownloadAttempts; $attempt++) {
        try {
            if ($attempt -eq 1) {
                $params = @{ url = $Url }
                if (-not [string]::IsNullOrWhiteSpace($Referrer)) {
                    $params.referrer = $Referrer
                }
                [void](Invoke-CdpCommand -Socket $socket -Method 'Page.navigate' -Params $params)
            }
            else {
                Write-Warning "Reload ulang img gagal: $Url"
                [void](Invoke-CdpCommand -Socket $socket -Method 'Page.reload' -Params @{ ignoreCache = $true })
            }

            [void](Wait-BrowserPageComplete -Socket $socket -Url $Url)

            $script = @'
(async () => {
    try {
        const response = await fetch(location.href, { cache: 'reload', credentials: 'include' });
        if (!response.ok) {
            return JSON.stringify({ ok: false, status: response.status, statusText: response.statusText || '' });
        }
        const contentType = response.headers.get('content-type') || '';
        const contentLength = response.headers.get('content-length') || '';
        const buffer = await response.arrayBuffer();
        if (contentLength && Number(contentLength) !== buffer.byteLength) {
            return JSON.stringify({
                ok: false,
                status: response.status,
                statusText: `content-length mismatch ${buffer.byteLength} != ${contentLength}`
            });
        }
        const bytes = new Uint8Array(buffer);
        if ((contentType || '').toLowerCase().startsWith('image/')) {
            const blob = new Blob([bytes], { type: contentType || 'application/octet-stream' });
            const objectUrl = URL.createObjectURL(blob);
            try {
                await new Promise((resolve, reject) => {
                    const img = new Image();
                    img.onload = () => resolve();
                    img.onerror = () => reject(new Error('image decode failed'));
                    img.src = objectUrl;
                    if (img.decode) {
                        img.decode().then(resolve).catch(reject);
                    }
                });
            } finally {
                URL.revokeObjectURL(objectUrl);
            }
        }
        let binary = '';
        const chunkSize = 0x8000;
        for (let i = 0; i < bytes.length; i += chunkSize) {
            binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunkSize));
        }
        return JSON.stringify({
            ok: true,
            status: response.status,
            finalUrl: location.href,
            contentType,
            contentLength,
            base64: btoa(binary)
        });
    } catch (error) {
        return JSON.stringify({ ok: false, error: String(error && error.message ? error.message : error) });
    }
})()
'@
            $json = Invoke-PageEval -Socket $socket -Expression $script
            $data = $json | ConvertFrom-Json
            if (-not $data.ok) {
                if ((Test-ObjectProperty -Object $data -Name 'error') -and $data.error) {
                    throw [string]$data.error
                }
                $status = if (Test-ObjectProperty -Object $data -Name 'status') { [string]$data.status } else { '' }
                $statusText = if (Test-ObjectProperty -Object $data -Name 'statusText') { [string]$data.statusText } else { '' }
                throw "HTTP $status $statusText"
            }

            $bytes = [Convert]::FromBase64String([string]$data.base64)
            $expectedLength = -1
            if ((Test-ObjectProperty -Object $data -Name 'contentLength') -and -not [string]::IsNullOrWhiteSpace([string]$data.contentLength)) {
                [Int64]::TryParse([string]$data.contentLength, [ref]$expectedLength) | Out-Null
            }

            $validationError = Test-ImageBytesComplete -Bytes $bytes -ContentType ([string]$data.contentType) -Url $Url -ExpectedLength $expectedLength
            if (-not [string]::IsNullOrWhiteSpace($validationError)) {
                throw $validationError
            }

            return [pscustomobject]@{
                Bytes = $bytes
                ContentType = [string]$data.contentType
                ContentLength = $expectedLength
                FinalUrl = [string]$data.finalUrl
            }
        }
        catch {
            $lastError = $_.Exception.Message
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

New-Item -ItemType Directory -Force -Path $BinRoot | Out-Null
New-Item -ItemType Directory -Force -Path $AssetsVideoRoot | Out-Null
New-Item -ItemType Directory -Force -Path $StrippedMhtmlRoot | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $TsvPath) | Out-Null

$files = Get-InputMhtmlFiles -Path $InputPath
$inputItem = Get-Item -LiteralPath $InputPath
if ($inputItem.PSIsContainer) {
    $inputBasePath = $inputItem.FullName
}
else {
    $inputBasePath = $inputItem.DirectoryName
}
$hashToPath = Import-ExistingHashMap -ManifestPath $TsvPath
$urlToRow = Import-ExistingUrlMap -ManifestPath $TsvPath
$rows = New-Object System.Collections.Generic.List[object]
$seenRows = New-Object 'System.Collections.Generic.Dictionary[string,bool]'
$stats = [ordered]@{
    Files = 0
    ExtractedParts = 0
    WrittenFiles = 0
    ReusedFiles = 0
    ClearedPartBodies = 0
    StrippedMhtmlFiles = 0
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

$assetSession = $null

foreach ($file in $files) {
    $stats.Files++
    Write-Host "Parsing $($file.FullName)"

    $text = [System.IO.File]::ReadAllText($file.FullName, $Latin1)
    $rootHeaders = Read-MimeHeaders -HeaderText (Get-InitialHeaderText -Text $text)
    $snapshotLocation = Get-UnfoldedHeaderValue -Headers $rootHeaders -Name 'Snapshot-Content-Location' -Url
    $contentType = Get-UnfoldedHeaderValue -Headers $rootHeaders -Name 'Content-Type'
    $boundary = Get-MimeBoundary -ContentType $contentType

    if (-not $boundary) {
        Write-Warning "Boundary tidak ditemukan: $($file.FullName)"
        continue
    }

    $parts = @(Get-MhtmlParts -Text $text -Boundary $boundary)
    $filePartLocations = New-Object 'System.Collections.Generic.Dictionary[string,bool]'
    foreach ($part in $parts) {
        $location = Get-UnfoldedHeaderValue -Headers $part.Headers -Name 'Content-Location' -Url
        if ($location -and -not $filePartLocations.ContainsKey($location)) {
            $filePartLocations[$location] = $true
        }

        if (-not $location -or $location -notmatch '^https://') {
            $stats.SkippedNonHttpsParts++
            continue
        }

        if ($snapshotLocation -and $location -eq $snapshotLocation) {
            $stats.SkippedSnapshotParts++
            continue
        }

        if ($urlToRow.ContainsKey($location)) {
            if (-not $seenRows.ContainsKey($location)) {
                $seenRows[$location] = $true
                $rows.Add($urlToRow[$location]) | Out-Null
            }

            $stats.SkippedExistingUrls++
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
            Write-Warning "Gagal decode $location ($transferEncoding) di $($file.Name): $($_.Exception.Message)"
            continue
        }

        if ($partContentType -match '(?i)^image/') {
            $validationError = Test-ImageBytesComplete -Bytes $bytes -ContentType $partContentType -Url $location
            if (-not [string]::IsNullOrWhiteSpace($validationError)) {
                $stats.InvalidLocalImageParts++
                Write-Warning "Gambar multipart corrupt setelah decode, skip: $location - $validationError"
                continue
            }
        }

        $sha256 = Get-Sha256Hex -Bytes $bytes
        $size = [Int64]$bytes.LongLength
        $contentKey = "$sha256`t$size"

        if ($hashToPath.ContainsKey($contentKey)) {
            $relativePath = $hashToPath[$contentKey]
            $stats.ReusedFiles++
        }
        else {
            do {
                $uuid = New-UuidV7
                $relativePath = Get-RelativeAssetPath -Uuid $uuid
                $fullPath = ConvertTo-FullPath -RelativePath $relativePath
            } while (Test-Path -LiteralPath $fullPath)

            [System.IO.File]::WriteAllBytes($fullPath, $bytes)
            $hashToPath[$contentKey] = $relativePath
            $stats.WrittenFiles++
        }

        $stats.ExtractedParts++
        $newRow = [pscustomobject]@{
            link = $location
            path = $relativePath
            type = $partContentType
            encoding = $storedEncoding
            sha256 = $sha256
            size_bytes = $size
        }
        $urlToRow[$location] = $newRow
        $seenRows[$location] = $true
        $rows.Add($newRow) | Out-Null
    }

    $missingImgParts = New-Object System.Collections.Generic.List[object]
    foreach ($assetRef in Get-MissingAssetRefsFromMhtml -Parts $parts -SnapshotLocation $snapshotLocation -PartLocations $filePartLocations) {
        $assetLink = [string]$assetRef.link
        if (-not $assetLink -or $filePartLocations.ContainsKey($assetLink)) {
            continue
        }

        $stats.MissingImgUrls++
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

                $stats.LinkedLocalVideoUrls++
            }
            catch {
                Write-Warning "Gagal proses video lokal: $assetLink - $($_.Exception.Message)"
                continue
            }
        }
        elseif ($urlToRow.ContainsKey($assetLink)) {
            $imgRow = $urlToRow[$assetLink]
            $contentType = Get-ContentTypeForManifestRow -Row $imgRow
            if (-not $seenRows.ContainsKey($assetLink)) {
                $seenRows[$assetLink] = $true
                $rows.Add($imgRow) | Out-Null
            }
            $stats.SkippedExistingUrls++
        }
        else {
            try {
                $assetSocket = Get-AssetSessionSocket -Session $assetSession
                if (-not $assetSocket -or $assetSocket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
                    if ($assetSession) {
                        Close-AssetDownloadSession -Session $assetSession
                    }
                    $assetSession = New-AssetDownloadSession
                }

                $download = Get-AssetBytesWithBrowser -Session $assetSession -Url $assetLink -Referrer $snapshotLocation
                $bytes = [byte[]]$download.Bytes
                $contentType = Get-ContentTypeFromBytesOrUrl -Bytes $bytes -Url $assetLink -ResponseContentType ([string]$download.ContentType)
                $manifestEncoding = Get-PreferredManifestEncoding -ContentType $contentType
                $sha256 = Get-Sha256Hex -Bytes $bytes
                $size = [Int64]$bytes.LongLength
                $contentKey = "$sha256`t$size"

                if ($hashToPath.ContainsKey($contentKey)) {
                    $relativePath = $hashToPath[$contentKey]
                    $stats.ReusedFiles++
                }
                else {
                    do {
                        $uuid = New-UuidV7
                        $relativePath = Get-RelativeAssetPath -Uuid $uuid
                        $fullPath = ConvertTo-FullPath -RelativePath $relativePath
                    } while (Test-Path -LiteralPath $fullPath)

                    [System.IO.File]::WriteAllBytes($fullPath, $bytes)
                    $hashToPath[$contentKey] = $relativePath
                    $stats.WrittenFiles++
                }

                $imgRow = [pscustomobject]@{
                    link = $assetLink
                    path = $relativePath
                    type = $contentType
                    encoding = $manifestEncoding
                    sha256 = $sha256
                    size_bytes = $size
                }
                $urlToRow[$assetLink] = $imgRow
                $seenRows[$assetLink] = $true
                $rows.Add($imgRow) | Out-Null
                $stats.DownloadedImgUrls++
            }
            catch {
                $stats.FailedImgUrls++
                Write-Warning "Gagal download asset tanpa multipart: $assetLink - $($_.Exception.Message)"
                continue
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

    $clearedResult = Clear-MhtmlExternalPartBodies -Text $text -Boundary $boundary -SnapshotLocation $snapshotLocation -UrlRows $urlToRow -AdditionalParts ([object[]]$missingImgParts.ToArray())
    if ($clearedResult.Cleared -gt 0 -or $clearedResult.Added -gt 0) {
        $relativeMhtmlPath = Get-RelativePathFromBase -BasePath $inputBasePath -FullPath $file.FullName
        $outputMhtmlPath = Join-Path $StrippedMhtmlRoot $relativeMhtmlPath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputMhtmlPath) | Out-Null
        [System.IO.File]::WriteAllText($outputMhtmlPath, $clearedResult.Text, $Latin1)
        $stats.ClearedPartBodies += $clearedResult.Cleared
        $stats.AddedMissingImgParts += $clearedResult.Added
        $stats.StrippedMhtmlFiles++
    }
}

Close-AssetDownloadSession -Session $assetSession
Close-EdgeBrowser

$tsvLines = New-Object System.Collections.Generic.List[string]
$tsvLines.Add("link`tpath`ttype`tencoding`tsha256`tsize_bytes") | Out-Null
foreach ($row in ($rows | Sort-Object link, path)) {
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

if (Test-Path -LiteralPath $TsvPath) {
    Copy-Item -LiteralPath $TsvPath -Destination ($TsvPath + '.bak') -Force
}

[System.IO.File]::WriteAllLines($TsvPath, $tsvLines, $Utf8NoBom)

Write-Host ''
Write-Host "Done."
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
