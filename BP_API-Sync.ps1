[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$BaseDir = (Resolve-Path -LiteralPath $PSScriptRoot).Path.TrimEnd('\') + '\'
$ListPath = Join-Path $BaseDir 'mhtml\bp_api-list.tsv'
$FolderPath = Join-Path $BaseDir 'mhtml\BlueprintAPI'

if (-not (Test-Path -LiteralPath $ListPath -PathType Leaf)) {
    throw ('File TSV tidak ditemukan: ' + $ListPath)
}

if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
    throw ('Folder tidak ditemukan: ' + $FolderPath)
}

function Get-Key {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $null
    }

    $path = $PathValue.Trim().Trim([char]34) -replace '/', '\'
    while ($path.StartsWith('.\')) {
        $path = $path.Substring(2)
    }

    if ([IO.Path]::IsPathRooted($path)) {
        $fullPath = [IO.Path]::GetFullPath($path)
        if ($fullPath.StartsWith($BaseDir, [StringComparison]::OrdinalIgnoreCase)) {
            $path = $fullPath.Substring($BaseDir.Length)
        }
    }

    return $path.TrimStart('\').ToLowerInvariant()
}

function Add-Path {
    param(
        [hashtable]$Map,
        [hashtable]$DuplicateMap,
        [string]$PathValue
    )

    $key = Get-Key $PathValue
    if ($null -eq $key) {
        return
    }

    $displayPath = ($PathValue.Trim().Trim([char]34) -replace '/', '\').TrimStart('\')
    if ($Map.ContainsKey($key)) {
        $DuplicateMap[$key] = $Map[$key]
    }
    else {
        $Map[$key] = $displayPath
    }
}

$expected = @{}
$duplicates = @{}
Import-Csv -LiteralPath $ListPath -Delimiter "`t" | ForEach-Object {
    Add-Path $expected $duplicates $_.file
}

$actual = @{}
Get-ChildItem -LiteralPath $FolderPath -Recurse -File -Filter '*.mhtml' | ForEach-Object {
    $relativePath = $_.FullName.Substring($BaseDir.Length)
    $actual[(Get-Key $relativePath)] = $relativePath
}

$missing = @($expected.Keys | Where-Object { -not $actual.ContainsKey($_) } | Sort-Object)
$extra = @($actual.Keys | Where-Object { -not $expected.ContainsKey($_) } | Sort-Object)

Write-Host 'BP API Sync Check'
Write-Host ('TSV         : ' + $ListPath)
Write-Host ('Folder      : ' + $FolderPath)
Write-Host ('Daftar TSV  : ' + $expected.Count)
Write-Host ('File asli   : ' + $actual.Count)
Write-Host ('Cocok       : ' + ($expected.Count - $missing.Count))
Write-Host ''

Write-Host ('Kekurangan di folder (ada di TSV, tidak ada di file asli): ' + $missing.Count)
if ($missing.Count -eq 0) {
    Write-Host '  - tidak ada'
}
else {
    $missing | ForEach-Object { Write-Host ('  - ' + $expected[$_]) }
}
Write-Host ''

Write-Host ('Kelebihan di folder (ada di file asli, tidak ada di TSV): ' + $extra.Count)
if ($extra.Count -eq 0) {
    Write-Host '  - tidak ada'
}
else {
    $extra | ForEach-Object { Write-Host ('  + ' + $actual[$_]) }
}
Write-Host ''

Write-Host ('Duplikat path di TSV: ' + $duplicates.Count)
if ($duplicates.Count -eq 0) {
    Write-Host '  - tidak ada'
}
else {
    $duplicates.Keys | Sort-Object | ForEach-Object { Write-Host ('  ! ' + $duplicates[$_]) }
}
Write-Host ''

if ($missing.Count -eq 0 -and $extra.Count -eq 0 -and $duplicates.Count -eq 0) {
    Write-Host 'Kesimpulan: SAMA'
    exit 0
}

Write-Host 'Kesimpulan: BERBEDA'
exit 1
