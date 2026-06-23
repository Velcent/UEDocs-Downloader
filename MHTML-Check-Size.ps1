[CmdletBinding()]
param(
    [string]$InputPath = '',
    [int]$MaxSizeKB = 650
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $InputPath) {
    $InputPath = Join-Path $PSScriptRoot 'mhtml'
}

if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "Folder tidak ditemukan: $InputPath"
}

$maxBytes = [int64]$MaxSizeKB * 1024
$files = @(Get-ChildItem -LiteralPath $InputPath -Recurse -File -Filter '*.mhtml' |
    Where-Object { $_.Length -lt $maxBytes } |
    Sort-Object FullName)

if ($files.Count -eq 0) {
    Write-Host "Tidak ada file .mhtml kurang dari $MaxSizeKB KB di $InputPath"
    exit 0
}

Write-Host "File .mhtml kurang dari $MaxSizeKB KB:"
Write-Host ''

$files | ForEach-Object {
    [pscustomobject]@{
        SizeKB = [Math]::Round($_.Length / 1KB, 2)
        Path = $_.FullName
    }
} | Format-Table -AutoSize

exit 1
