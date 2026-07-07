[CmdletBinding()]
param(
    [string]$InputPath = '',
    [int]$MaxSizeKB,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PSBoundParameters.ContainsKey('MaxSizeKB')) {
    throw "Parameter -MaxSizeKB wajib diisi. Contoh: .\MHTML-Remover.bat -MaxSizeKB 650 -WhatIf"
}

if ($MaxSizeKB -le 0) {
    throw "Parameter -MaxSizeKB harus lebih besar dari 0."
}

if (-not $InputPath) {
    $InputPath = Join-Path $PSScriptRoot 'mhtml'
}

if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "Folder tidak ditemukan: $InputPath"
}

$maxBytes = [int64]$MaxSizeKB * 1024
$mhtmlRoot = Join-Path $PSScriptRoot 'mhtml'

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

function Get-NormalizedPathKey {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    try {
        return ([System.IO.Path]::GetFullPath($Path)).ToLowerInvariant()
    }
    catch {
        return ''
    }
}

function Backup-File {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = "$Path.$timestamp.bak"
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    return $backupPath
}

function Remove-ListRowsByDeletedFiles {
    param(
        [string]$ListPath,
        [hashtable]$DeletedFileKeys
    )

    if (-not (Test-Path -LiteralPath $ListPath)) {
        Write-Host "List tidak ditemukan, lewati: $ListPath"
        return 0
    }

    $lines = @(Get-Content -LiteralPath $ListPath)
    if ($lines.Count -eq 0) {
        return 0
    }

    $header = [string]$lines[0]
    $columns = $header -split "`t"
    $fileIndex = [Array]::IndexOf($columns, 'file')
    if ($fileIndex -lt 0) {
        Write-Warning "Kolom file tidak ditemukan di list: $ListPath"
        return 0
    }

    $kept = New-Object System.Collections.Generic.List[string]
    $kept.Add($header)
    $removed = 0

    foreach ($line in @($lines | Select-Object -Skip 1)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $parts = [string]$line -split "`t", ($columns.Count)
        if ($parts.Count -le $fileIndex) {
            $kept.Add($line)
            continue
        }

        $filePath = ConvertTo-LocalPathFromListValue $parts[$fileIndex]
        $fileKey = Get-NormalizedPathKey $filePath
        if ($fileKey -and $DeletedFileKeys.ContainsKey($fileKey)) {
            $removed++
            continue
        }

        $kept.Add($line)
    }

    if ($removed -gt 0) {
        if ($WhatIf) {
            Write-Host "DRY RUN: akan hapus $removed baris dari $ListPath"
        }
        else {
            $backupPath = Backup-File -Path $ListPath
            if ($backupPath) {
                Write-Host "Backup list: $backupPath"
            }

            $tempPath = "$ListPath.tmp"
            Set-Content -LiteralPath $tempPath -Value $kept -Encoding UTF8
            Move-Item -LiteralPath $tempPath -Destination $ListPath -Force
            Write-Host "Update list: hapus $removed baris dari $ListPath"
        }
    }

    return $removed
}

$files = @(Get-ChildItem -LiteralPath $InputPath -Recurse -File -Filter '*.mhtml' |
    Where-Object { $_.Length -lt $maxBytes } |
    Sort-Object FullName)

if ($files.Count -eq 0) {
    Write-Host "Tidak ada file .mhtml kurang dari $MaxSizeKB KB di $InputPath"
    exit 0
}

Write-Host "File .mhtml kurang dari $MaxSizeKB KB: $($files.Count)"

$deletedFileKeys = @{}
foreach ($file in $files) {
    $key = Get-NormalizedPathKey $file.FullName
    if ($key) {
        $deletedFileKeys[$key] = $true
    }
}

foreach ($file in $files) {
    $sizeKb = [Math]::Round($file.Length / 1KB, 2)
    if ($WhatIf) {
        Write-Host "DRY RUN: delete $sizeKb KB - $($file.FullName)"
    }
    else {
        Remove-Item -LiteralPath $file.FullName -Force
        Write-Host "Delete $sizeKb KB - $($file.FullName)"
    }
}

$totalRowsRemoved = 0
foreach ($listPath in @(
    (Join-Path $mhtmlRoot 'cpp_api-list.tsv'),
    (Join-Path $mhtmlRoot 'bp_api-list.tsv')
)) {
    $totalRowsRemoved += Remove-ListRowsByDeletedFiles -ListPath $listPath -DeletedFileKeys $deletedFileKeys
}

Write-Host ''
Write-Host "Selesai. File dihapus: $($files.Count). Baris list dihapus: $totalRowsRemoved."
