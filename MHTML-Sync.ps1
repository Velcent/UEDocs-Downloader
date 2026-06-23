[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('All', 'Missing', 'Extra', 'Kurang', 'Lebih')]
    [string]$Show = 'All',

    [string]$XmlName = ''
)

$ErrorActionPreference = 'Stop'

switch ($Show) {
    'Kurang' { $Show = 'Missing' }
    'Lebih' { $Show = 'Extra' }
}

$BaseDir = (Resolve-Path -LiteralPath $PSScriptRoot).Path.TrimEnd('\') + '\'
$MhtmlRoot = Join-Path $BaseDir 'mhtml'

if (-not (Test-Path -LiteralPath $MhtmlRoot -PathType Container)) {
    throw ('Folder tidak ditemukan: ' + $MhtmlRoot)
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

function Write-PathSection {
    param(
        [string]$Title,
        [object[]]$Keys,
        [hashtable]$Map,
        [string]$Prefix
    )

    Write-Host ($Title + ': ' + $Keys.Count)
    if ($Keys.Count -eq 0) {
        Write-Host '  - tidak ada'
    }
    else {
        $Keys | ForEach-Object { Write-Host ('  ' + $Prefix + ' ' + $Map[$_]) }
    }
    Write-Host ''
}

function Get-MhtmlXmlFiles {
    if ([string]::IsNullOrWhiteSpace($XmlName)) {
        return @(Get-ChildItem -LiteralPath $MhtmlRoot -File -Filter '*.xml' | Sort-Object Name)
    }

    $name = $XmlName
    if (-not $name.EndsWith('.xml', [StringComparison]::OrdinalIgnoreCase)) {
        $name = "$name.xml"
    }

    $path = Join-Path $MhtmlRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw ('File XML tidak ditemukan: ' + $path)
    }

    return @(Get-Item -LiteralPath $path)
}

function Get-SyncTarget {
    param([IO.FileInfo]$XmlFile)

    $baseName = [IO.Path]::GetFileNameWithoutExtension($XmlFile.Name)
    return [pscustomobject]@{
        Name = $baseName
        XmlPath = $XmlFile.FullName
        ListPath = (Join-Path $XmlFile.DirectoryName "$baseName-list.tsv")
        FolderPath = (Join-Path $XmlFile.DirectoryName $baseName)
    }
}

$targets = @(Get-MhtmlXmlFiles | ForEach-Object { Get-SyncTarget -XmlFile $_ })
if ($targets.Count -eq 0) {
    throw ('Tidak ada file XML langsung di folder: ' + $MhtmlRoot)
}

$hadDifference = $false
foreach ($target in $targets) {
    if (-not (Test-Path -LiteralPath $target.ListPath -PathType Leaf)) {
        throw ('File TSV tidak ditemukan: ' + $target.ListPath)
    }

    if (-not (Test-Path -LiteralPath $target.FolderPath -PathType Container)) {
        throw ('Folder tidak ditemukan: ' + $target.FolderPath)
    }

    $expected = @{}
    $duplicates = @{}
    Import-Csv -LiteralPath $target.ListPath -Delimiter "`t" | ForEach-Object {
        Add-Path $expected $duplicates $_.file
    }

    $actual = @{}
    Get-ChildItem -LiteralPath $target.FolderPath -Recurse -File -Filter '*.mhtml' | ForEach-Object {
        $relativePath = $_.FullName.Substring($BaseDir.Length)
        $actual[(Get-Key $relativePath)] = $relativePath
    }

    $missing = @($expected.Keys | Where-Object { -not $actual.ContainsKey($_) } | Sort-Object)
    $extra = @($actual.Keys | Where-Object { -not $expected.ContainsKey($_) } | Sort-Object)
    $duplicateKeys = @($duplicates.Keys | Sort-Object)

    Write-Host 'MHTML Sync Check'
    Write-Host ('XML         : ' + $target.XmlPath)
    Write-Host ('TSV         : ' + $target.ListPath)
    Write-Host ('Folder      : ' + $target.FolderPath)
    Write-Host ('Daftar TSV  : ' + $expected.Count)
    Write-Host ('File asli   : ' + $actual.Count)
    Write-Host ('Cocok       : ' + ($expected.Count - $missing.Count))
    Write-Host ('Kekurangan  : ' + $missing.Count)
    Write-Host ('Kelebihan   : ' + $extra.Count)
    Write-Host ('Duplikat    : ' + $duplicates.Count)
    Write-Host ('Output      : ' + $Show)
    Write-Host ''

    if ($Show -eq 'All' -or $Show -eq 'Missing') {
        Write-PathSection 'Kekurangan di folder (ada di TSV, tidak ada di file asli)' $missing $expected '-'
    }

    if ($Show -eq 'All' -or $Show -eq 'Extra') {
        Write-PathSection 'Kelebihan di folder (ada di file asli, tidak ada di TSV)' $extra $actual '+'
    }

    if ($Show -eq 'All') {
        Write-PathSection 'Duplikat path di TSV' $duplicateKeys $duplicates '!'
    }

    if ($missing.Count -eq 0 -and $extra.Count -eq 0 -and $duplicates.Count -eq 0) {
        Write-Host ('Kesimpulan ' + $target.Name + ': SAMA')
    }
    else {
        Write-Host ('Kesimpulan ' + $target.Name + ': BERBEDA')
        $hadDifference = $true
    }

    Write-Host ''
}

if ($hadDifference) {
    exit 1
}

exit 0
