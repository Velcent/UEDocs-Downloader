[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Url,
    [string]$MhtmlRoot = '',
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (-not $MhtmlRoot) {
    $MhtmlRoot = Join-Path $PSScriptRoot 'assets\mhtml'
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot 'assets\mhtml-search.tsv'
}

function ConvertTo-TsvValue {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ''
    }

    return (($Value -replace "`t", ' ') -replace "(`r`n|`r|`n)", ' ').Trim()
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

function Get-UrlVariants {
    param([string]$Value)

    $seen = @{}
    $variants = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(
        $Value
        ([System.Net.WebUtility]::HtmlDecode($Value))
        ($Value -replace '&', '&amp;')
        (([System.Net.WebUtility]::HtmlDecode($Value)) -replace '&', '&amp;')
    )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        if (-not $seen.ContainsKey($candidate)) {
            $seen[$candidate] = $true
            $variants.Add($candidate) | Out-Null
        }
    }

    return $variants.ToArray()
}

function Find-UrlInText {
    param(
        [string]$Path,
        [string[]]$Variants
    )

    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        foreach ($variant in $Variants) {
            if ($line.IndexOf($variant, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return 'line'
            }
        }
    }

    return ''
}

if (-not (Test-Path -LiteralPath $MhtmlRoot)) {
    throw "Folder MHTML tidak ditemukan: $MhtmlRoot"
}

$variants = @(Get-UrlVariants -Value $Url)
$results = New-Object System.Collections.Generic.List[object]
$files = @(Get-ChildItem -LiteralPath $MhtmlRoot -Filter *.mhtml -File -Recurse | Sort-Object FullName)
$total = $files.Count
$index = 0

foreach ($file in $files) {
    $index++
    if ($index -eq 1 -or $index % 100 -eq 0 -or $index -eq $total) {
        Write-Host ("Scan {0}/{1}: {2}" -f $index, $total, $file.Name)
    }

    $matchKind = Find-UrlInText -Path $file.FullName -Variants $variants
    if (-not $matchKind) {
        continue
    }

    $relativePath = Get-RelativePathFromBase -BasePath $MhtmlRoot -FullPath $file.FullName
    $results.Add([pscustomobject]@{
        file = ($relativePath -replace '\\', '/')
        match_kind = $matchKind
        url = $Url
    }) | Out-Null

    Write-Host ("MATCH: {0}" -f ($relativePath -replace '\\', '/'))
}

$writer = $null
try {
    $writer = [System.IO.StreamWriter]::new($OutputPath, $false, $Utf8NoBom, 1048576)
    $writer.WriteLine("file`tmatch_kind`turl")
    foreach ($result in $results) {
        $writer.WriteLine((@(
            ConvertTo-TsvValue $result.file
            ConvertTo-TsvValue $result.match_kind
            ConvertTo-TsvValue $result.url
        ) -join "`t"))
    }
}
finally {
    if ($writer) {
        $writer.Dispose()
    }
}

Write-Host ''
Write-Host 'Done.'
Write-Host "Scanned : $total"
Write-Host "Matched : $($results.Count)"
Write-Host "Output  : $OutputPath"
