[CmdletBinding()]
param(
    [string]$AssetsRoot = '',
    [string]$InputPath = '',
    [string]$TsvPath = '',
    [string]$OutputRoot = '',
    [switch]$PreserveEncoding
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Latin1 = [System.Text.Encoding]::GetEncoding(28591)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (-not $AssetsRoot) {
    $AssetsRoot = Join-Path $PSScriptRoot 'assets'
}

if (-not $InputPath) {
    $InputPath = Join-Path $AssetsRoot 'mhtml'
}

if (-not $TsvPath) {
    $TsvPath = Join-Path $AssetsRoot 'mhtml-uuid.tsv'
}

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $AssetsRoot 'combined'
}

$ProjectRootFull = [System.IO.Path]::GetFullPath($PSScriptRoot)

function ConvertTo-FullPath {
    param([string]$RelativePath)

    return Join-Path $ProjectRootFull ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
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

function ConvertTo-Base64Body {
    param([byte[]]$Bytes)

    $base64 = [Convert]::ToBase64String($Bytes)
    if ($base64.Length -eq 0) {
        return ''
    }

    $lines = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $base64.Length; $i += 76) {
        $length = [Math]::Min(76, $base64.Length - $i)
        $lines.Add($base64.Substring($i, $length)) | Out-Null
    }

    return ($lines -join "`r`n")
}

function ConvertTo-QuotedPrintableBody {
    param([byte[]]$Bytes)

    $builder = New-Object System.Text.StringBuilder
    $lineLength = 0

    foreach ($byte in $Bytes) {
        if ($byte -eq 13) {
            continue
        }

        if ($byte -eq 10) {
            $builder.Append("`r`n") | Out-Null
            $lineLength = 0
            continue
        }

        $token = ''
        if (($byte -ge 33 -and $byte -le 60) -or ($byte -ge 62 -and $byte -le 126) -or $byte -eq 9 -or $byte -eq 32) {
            $token = [string][char]$byte
        }
        else {
            $token = '=' + $byte.ToString('X2')
        }

        if ($lineLength + $token.Length -gt 73) {
            $builder.Append("=`r`n") | Out-Null
            $lineLength = 0
        }

        $builder.Append($token) | Out-Null
        $lineLength += $token.Length
    }

    return $builder.ToString()
}

function ConvertTo-MimeBody {
    param(
        [byte[]]$Bytes,
        [string]$Encoding
    )

    switch ($Encoding.ToLowerInvariant()) {
        'base64' {
            return ConvertTo-Base64Body -Bytes $Bytes
        }
        'quoted-printable' {
            return ConvertTo-QuotedPrintableBody -Bytes $Bytes
        }
        default {
            return $Latin1.GetString($Bytes)
        }
    }
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

function Import-AssetMap {
    param([string]$ManifestPath)

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "Manifest tidak ditemukan: $ManifestPath"
    }

    $map = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    foreach ($row in (Import-Csv -LiteralPath $ManifestPath -Delimiter "`t")) {
        if (-not $row.link -or -not $row.path) {
            continue
        }

        if (-not $map.ContainsKey($row.link)) {
            $map[$row.link] = $row
        }
    }

    return $map
}

function Restore-MhtmlBodies {
    param(
        [string]$Text,
        [string]$Boundary,
        [System.Collections.Generic.Dictionary[string,object]]$AssetMap
    )

    $pattern = '(?m)^--' + [regex]::Escape($Boundary) + '(?<closing>--)?[ \t]*\r?$'
    $boundaryMatches = [regex]::Matches($Text, $pattern)
    if ($boundaryMatches.Count -lt 2) {
        return [pscustomobject]@{
            Text = $Text
            Restored = 0
            Missing = 0
        }
    }

    $builder = New-Object System.Text.StringBuilder
    $builder.Append($Text.Substring(0, $boundaryMatches[0].Index)) | Out-Null
    $restored = 0
    $missing = 0

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

        if (-not $location -or -not $AssetMap.ContainsKey($location)) {
            $builder.Append($segment) | Out-Null
            continue
        }

        $row = $AssetMap[$location]
        $assetPath = ConvertTo-FullPath -RelativePath ([string]$row.path)
        if (-not (Test-Path -LiteralPath $assetPath)) {
            Write-Warning "Asset tidak ditemukan untuk $location : $assetPath"
            $builder.Append($segment) | Out-Null
            $missing++
            continue
        }

        $encoding = if ($row.encoding) { [string]$row.encoding } else { 'base64' }
        if (-not $encoding) {
            $encoding = 'base64'
        }

        $contentType = ''
        if ($row.PSObject.Properties.Match('type').Count -gt 0) {
            $contentType = [string]$row.type
        }

        $bytes = [System.IO.File]::ReadAllBytes($assetPath)
        $body = ConvertTo-MimeBody -Bytes $bytes -Encoding $encoding
        $updatedHeaderText = Update-OrAddHeader -HeaderText $headerText -Name 'Content-Transfer-Encoding' -Value $encoding
        $updatedHeaderText = Update-OrAddHeader -HeaderText $updatedHeaderText -Name 'Content-Type' -Value $contentType

        $builder.Append($updatedHeaderText) | Out-Null
        $builder.Append($separator.Value) | Out-Null
        $builder.Append($body) | Out-Null
        if ($body.Length -gt 0) {
            $builder.Append("`r`n") | Out-Null
        }
        $restored++
    }

    $last = $boundaryMatches[($boundaryMatches.Count - 1)]
    $builder.Append($Text.Substring($last.Index)) | Out-Null

    return [pscustomobject]@{
        Text = $builder.ToString()
        Restored = $restored
        Missing = $missing
    }
}

function Write-Base64Body {
    param(
        [System.IO.StreamWriter]$Writer,
        [byte[]]$Bytes
    )

    $base64 = [Convert]::ToBase64String($Bytes)
    for ($i = 0; $i -lt $base64.Length; $i += 76) {
        $length = [Math]::Min(76, $base64.Length - $i)
        $Writer.Write($base64.Substring($i, $length))
        $Writer.Write("`r`n")
    }
}

function Write-MimeBody {
    param(
        [System.IO.StreamWriter]$Writer,
        [byte[]]$Bytes,
        [string]$Encoding
    )

    switch ($Encoding.ToLowerInvariant()) {
        'base64' {
            Write-Base64Body -Writer $Writer -Bytes $Bytes
        }
        'quoted-printable' {
            $Writer.Write($(ConvertTo-QuotedPrintableBody -Bytes $Bytes))
            $Writer.Write("`r`n")
        }
        default {
            $Writer.Write($Latin1.GetString($Bytes))
            $Writer.Write("`r`n")
        }
    }
}

function Write-BodyFromAssetFile {
    param(
        [System.IO.StreamWriter]$Writer,
        [string]$AssetPath,
        [string]$Encoding
    )

    $bytes = [System.IO.File]::ReadAllBytes($AssetPath)
    if ($Encoding -and $Encoding.ToLowerInvariant() -eq 'base64') {
        Write-Base64Body -Writer $Writer -Bytes $bytes
        return
    }

    if ($bytes.Length -gt 0) {
        $Writer.Write($Latin1.GetString($bytes))
        $lastByte = $bytes[$bytes.Length - 1]
        if ($lastByte -ne 10 -and $lastByte -ne 13) {
            $Writer.Write("`r`n")
        }
    }
}

function Test-MimeBoundaryLine {
    param(
        [string]$Line,
        [string]$Boundary
    )

    if ($null -eq $Line) {
        return $false
    }

    return [regex]::IsMatch($Line, '^--' + [regex]::Escape($Boundary) + '(--)?[ \t]*$')
}

function Test-MimeClosingBoundaryLine {
    param(
        [string]$Line,
        [string]$Boundary
    )

    if ($null -eq $Line) {
        return $false
    }

    return [regex]::IsMatch($Line, '^--' + [regex]::Escape($Boundary) + '--[ \t]*$')
}

function Write-RestoredMhtmlStream {
    param(
        [string]$InputPath,
        [System.Collections.Generic.Dictionary[string,object]]$AssetMap,
        [string]$OutputPath
    )

    $reader = New-Object System.IO.StreamReader($InputPath, $Latin1, $false)
    $writer = New-Object System.IO.StreamWriter($OutputPath, $false, $Latin1)
    $writer.NewLine = "`r`n"
    $restored = 0
    $missing = 0
    $hasBoundary = $false

    try {
        $rootHeaderLines = New-Object System.Collections.ArrayList
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line) {
                break
            }

            [void]$rootHeaderLines.Add($line)
            if ($line -eq '') {
                break
            }
        }

        foreach ($line in $rootHeaderLines) {
            $writer.WriteLine($line)
        }

        $rootHeaderText = ''
        if ($rootHeaderLines.Count -gt 0) {
            $headerOnlyLines = @($rootHeaderLines | Where-Object { $_ -ne '' })
            $rootHeaderText = ($headerOnlyLines -join "`r`n")
        }

        $rootHeaders = Read-MimeHeaders -HeaderText $rootHeaderText
        $boundary = Get-MimeBoundary -ContentType (Get-UnfoldedHeaderValue -Headers $rootHeaders -Name 'Content-Type')
        if (-not $boundary) {
            while (($line = $reader.ReadLine()) -ne $null) {
                $writer.WriteLine($line)
            }

            return [pscustomobject]@{
                Restored = 0
                Missing = 0
                HasBoundary = $false
            }
        }

        $hasBoundary = $true
        $pendingLine = $null
        while ($true) {
            if ($null -ne $pendingLine) {
                $line = $pendingLine
                $pendingLine = $null
            }
            else {
                $line = $reader.ReadLine()
            }

            if ($null -eq $line) {
                break
            }

            if (-not (Test-MimeBoundaryLine -Line $line -Boundary $boundary)) {
                $writer.WriteLine($line)
                continue
            }

            $writer.WriteLine($line)
            if (Test-MimeClosingBoundaryLine -Line $line -Boundary $boundary) {
                continue
            }

            $partHeaderLines = New-Object System.Collections.ArrayList
            while ($true) {
                $headerLine = $reader.ReadLine()
                if ($null -eq $headerLine) {
                    break
                }

                if ($headerLine -eq '') {
                    break
                }

                [void]$partHeaderLines.Add($headerLine)
            }

            $headerText = ($partHeaderLines -join "`r`n")
            $headers = Read-MimeHeaders -HeaderText $headerText
            $location = Get-UnfoldedHeaderValue -Headers $headers -Name 'Content-Location' -Url

            if (-not $location -or -not $AssetMap.ContainsKey($location)) {
                foreach ($headerLine in $partHeaderLines) {
                    $writer.WriteLine($headerLine)
                }
                $writer.WriteLine('')

                while ($true) {
                    $bodyLine = $reader.ReadLine()
                    if ($null -eq $bodyLine) {
                        break
                    }

                    if (Test-MimeBoundaryLine -Line $bodyLine -Boundary $boundary) {
                        $pendingLine = $bodyLine
                        break
                    }

                    $writer.WriteLine($bodyLine)
                }

                continue
            }

            $row = $AssetMap[$location]
            $assetPath = ConvertTo-FullPath -RelativePath ([string]$row.path)
            if (-not (Test-Path -LiteralPath $assetPath)) {
                Write-Warning "Asset tidak ditemukan untuk $location : $assetPath"
                foreach ($headerLine in $partHeaderLines) {
                    $writer.WriteLine($headerLine)
                }
                $writer.WriteLine('')
                $missing++

                while ($true) {
                    $bodyLine = $reader.ReadLine()
                    if ($null -eq $bodyLine) {
                        break
                    }

                    if (Test-MimeBoundaryLine -Line $bodyLine -Boundary $boundary) {
                        $pendingLine = $bodyLine
                        break
                    }

                    $writer.WriteLine($bodyLine)
                }

                continue
            }

            $encoding = if ($row.encoding) { [string]$row.encoding } else { 'base64' }
            if (-not $encoding) {
                $encoding = 'base64'
            }

            $contentType = ''
            if ($row.PSObject.Properties.Match('type').Count -gt 0) {
                $contentType = [string]$row.type
            }

            $updatedHeaderText = Update-OrAddHeader -HeaderText $headerText -Name 'Content-Transfer-Encoding' -Value $encoding
            $updatedHeaderText = Update-OrAddHeader -HeaderText $updatedHeaderText -Name 'Content-Type' -Value $contentType
            foreach ($updatedLine in ([regex]::Split($updatedHeaderText, "\r?\n"))) {
                $writer.WriteLine($updatedLine)
            }
            $writer.WriteLine('')
            Write-BodyFromAssetFile -Writer $writer -AssetPath $assetPath -Encoding $encoding
            $restored++

            while ($true) {
                $bodyLine = $reader.ReadLine()
                if ($null -eq $bodyLine) {
                    break
                }

                if (Test-MimeBoundaryLine -Line $bodyLine -Boundary $boundary) {
                    $pendingLine = $bodyLine
                    break
                }
            }
        }
    }
    finally {
        $reader.Dispose()
        $writer.Dispose()
    }

    return [pscustomobject]@{
        Restored = $restored
        Missing = $missing
        HasBoundary = $hasBoundary
    }
}

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

$assetMap = Import-AssetMap -ManifestPath $TsvPath
$files = Get-InputMhtmlFiles -Path $InputPath
$inputItem = Get-Item -LiteralPath $InputPath
if ($inputItem.PSIsContainer) {
    $inputBasePath = $inputItem.FullName
}
else {
    $inputBasePath = $inputItem.DirectoryName
}

$stats = [ordered]@{
    Files = 0
    Written = 0
    RestoredParts = 0
    MissingAssets = 0
    SkippedNoBoundary = 0
}

foreach ($file in $files) {
    $stats.Files++
    Write-Host "Combining $($file.FullName)"

    $relativePath = Get-RelativePathFromBase -BasePath $inputBasePath -FullPath $file.FullName
    $outputPath = Join-Path $OutputRoot $relativePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputPath) | Out-Null
    $result = Write-RestoredMhtmlStream -InputPath $file.FullName -AssetMap $assetMap -OutputPath $outputPath

    if (-not $result.HasBoundary) {
        Write-Warning "Boundary tidak ditemukan: $($file.FullName)"
        $stats.SkippedNoBoundary++
    }

    $stats.Written++
    $stats.RestoredParts += $result.Restored
    $stats.MissingAssets += $result.Missing
}

Write-Host ''
Write-Host 'Done.'
Write-Host "Files scanned       : $($stats.Files)"
Write-Host "Files written       : $($stats.Written)"
Write-Host "Parts restored      : $($stats.RestoredParts)"
Write-Host "Missing assets      : $($stats.MissingAssets)"
Write-Host "Skipped no boundary : $($stats.SkippedNoBoundary)"
Write-Host "Manifest            : $TsvPath"
Write-Host "Input folder        : $InputPath"
Write-Host "Output folder       : $OutputRoot"
pause
