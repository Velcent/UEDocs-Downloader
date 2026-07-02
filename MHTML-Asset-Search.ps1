[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Url,
    [string]$MhtmlRoot = '',
    [string]$AssetBinRoot = '',
    [string]$OutputPath = '',
    [switch]$DeleteMatched
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (-not $MhtmlRoot) {
    $defaultMhtmlRoots = @(
        [pscustomobject]@{
            Path = Join-Path $PSScriptRoot 'assets\mhtml'
            Prefix = ''
        }
        [pscustomobject]@{
            Path = Join-Path $PSScriptRoot 'mhtml'
            Prefix = 'mhtml/'
        }
    )
}
else {
    $defaultMhtmlRoots = @(
        [pscustomobject]@{
            Path = $MhtmlRoot
            Prefix = ''
        }
    )
}

if (-not $AssetBinRoot) {
    $AssetBinRoot = Join-Path $PSScriptRoot 'assets\bin'
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
        [object[]]$Terms
    )

    $matchedTerms = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    $reader = $null
    try {
        $reader = [System.IO.StreamReader]::new($Path)
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            foreach ($term in $Terms) {
                if ($seen.ContainsKey($term.Value)) {
                    continue
                }

                foreach ($variant in $term.Variants) {
                    if ($line.IndexOf($variant, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $seen[$term.Value] = $true
                        $matchedTerms.Add($term.Value) | Out-Null
                        break
                    }
                }
            }

            if ($matchedTerms.Count -eq $Terms.Count) {
                break
            }
        }
    }
    finally {
        if ($reader) {
            $reader.Dispose()
        }
    }

    return $matchedTerms.ToArray()
}

function Get-SearchFiles {
    param(
        [object[]]$MhtmlPaths,
        [string]$BinPath
    )

    $items = New-Object System.Collections.Generic.List[object]

    foreach ($mhtmlPath in $MhtmlPaths) {
        foreach ($file in @(Get-ChildItem -LiteralPath $mhtmlPath.Path -Filter *.mhtml -File -Recurse | Sort-Object FullName)) {
            $items.Add([pscustomobject]@{
                File = $file
                BasePath = $mhtmlPath.Path
                Prefix = $mhtmlPath.Prefix
            }) | Out-Null
        }
    }

    if (Test-Path -LiteralPath $BinPath) {
        foreach ($file in @(Get-ChildItem -LiteralPath $BinPath -Filter *.html -File -Recurse | Sort-Object FullName)) {
            $items.Add([pscustomobject]@{
                File = $file
                BasePath = $BinPath
                Prefix = 'assets/bin/'
            }) | Out-Null
        }
    }

    return $items.ToArray()
}

$mhtmlSearchRoots = @($defaultMhtmlRoots | Where-Object { Test-Path -LiteralPath $_.Path })
if ($mhtmlSearchRoots.Count -eq 0) {
    $missingRoots = (($defaultMhtmlRoots | ForEach-Object { $_.Path }) -join ', ')
    throw "Folder MHTML tidak ditemukan: $missingRoots"
}

$searchTerms = @(
    foreach ($value in $Url) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        [pscustomobject]@{
            Value = $value
            Variants = [string[]]@(Get-UrlVariants -Value $value)
        }
    }
)
if ($searchTerms.Count -eq 0) {
    throw 'Minimal satu string pencarian harus diisi.'
}

$results = New-Object System.Collections.Generic.List[object]
$files = @(Get-SearchFiles -MhtmlPaths $mhtmlSearchRoots -BinPath $AssetBinRoot)
$total = $files.Count
$index = 0
$deletedCount = 0

foreach ($item in $files) {
    $index++
    $file = $item.File
    if ($index -eq 1 -or $index % 100 -eq 0 -or $index -eq $total) {
        Write-Host ("Scan {0}/{1}: {2}" -f $index, $total, $file.Name)
    }

    $matchedUrls = @(Find-UrlInText -Path $file.FullName -Terms $searchTerms)
    if ($matchedUrls.Count -eq 0) {
        continue
    }

    $relativePath = (Get-RelativePathFromBase -BasePath $item.BasePath -FullPath $file.FullName)
    if ($item.Prefix) {
        $relativePath = $item.Prefix + ($relativePath -replace '\\', '/')
    }

    foreach ($matchedUrl in $matchedUrls) {
        $results.Add([pscustomobject]@{
            file = ($relativePath -replace '\\', '/')
            match_kind = 'line'
            url = $matchedUrl
        }) | Out-Null

        Write-Host ("MATCH: {0} :: {1}" -f ($relativePath -replace '\\', '/'), $matchedUrl)
    }

    if ($DeleteMatched -and $PSCmdlet.ShouldProcess($file.FullName, 'Delete matched file')) {
        Remove-Item -LiteralPath $file.FullName -Force
        $deletedCount++
        Write-Host ("DELETE: {0}" -f ($relativePath -replace '\\', '/'))
    }
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
Write-Host "Search  : $($searchTerms.Count)"
Write-Host "Scanned : $total"
Write-Host "Matched : $($results.Count)"
Write-Host "Deleted : $deletedCount"
Write-Host "Output  : $OutputPath"
