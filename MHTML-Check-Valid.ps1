[CmdletBinding()]
param(
    [string]$InputPath = '',
    [string]$OutputPath = '',
    [switch]$NoFileOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $InputPath) {
    $InputPath = Join-Path $PSScriptRoot 'mhtml'
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot 'mhtml-check-valid-invalid.tsv'
}

if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "Folder tidak ditemukan: $InputPath"
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

function Test-SnapshotContentLocationLine {
    param(
        [string]$Path,
        [ref]$Url,
        [ref]$Reason,
        [ref]$Line2
    )

    $Url.Value = ''
    $Reason.Value = ''
    $Line2.Value = ''

    try {
        $lines = @(Get-Content -LiteralPath $Path -TotalCount 2 -ErrorAction Stop)
    }
    catch {
        $Reason.Value = "Tidak bisa baca file: $($_.Exception.Message)"
        return $false
    }

    if ($lines.Count -lt 2) {
        $Reason.Value = 'File kurang dari 2 baris'
        return $false
    }

    $line = [string]$lines[1]
    $Line2.Value = $line

    $match = [regex]::Match($line, '^\s*Snapshot-Content-Location:\s*(?<url>https?://\S+)\s*$', 'IgnoreCase')
    if (-not $match.Success) {
        $Reason.Value = 'Baris kedua bukan Snapshot-Content-Location URL valid'
        return $false
    }

    $candidateUrl = [System.Net.WebUtility]::HtmlDecode($match.Groups['url'].Value.Trim())
    $uri = $null
    if (-not [Uri]::TryCreate($candidateUrl, [UriKind]::Absolute, [ref]$uri)) {
        $Reason.Value = 'URL Snapshot-Content-Location tidak bisa diparse'
        return $false
    }

    if ($uri.Scheme -notin @('http', 'https')) {
        $Reason.Value = "Scheme URL tidak didukung: $($uri.Scheme)"
        return $false
    }

    $Url.Value = $uri.AbsoluteUri
    return $true
}

$files = @(Get-ChildItem -LiteralPath $InputPath -Recurse -File -Filter '*.mhtml' | Sort-Object FullName)

if ($files.Count -eq 0) {
    Write-Host "Tidak ada file .mhtml di $InputPath"
    exit 0
}

$invalid = New-Object System.Collections.Generic.List[object]
$validCount = 0

foreach ($file in $files) {
    $url = ''
    $reason = ''
    $line2 = ''
    if (Test-SnapshotContentLocationLine -Path $file.FullName -Url ([ref]$url) -Reason ([ref]$reason) -Line2 ([ref]$line2)) {
        $validCount++
        continue
    }

    $invalid.Add([pscustomobject]@{
        file = ConvertTo-RelativeRootPath $file.FullName
        reason = $reason
        line2 = ($line2 -replace "`t", ' ' -replace "\r?\n", ' ').Trim()
    })
}

Write-Host "Total .mhtml: $($files.Count)"
Write-Host "Valid: $validCount"
Write-Host "Invalid: $($invalid.Count)"

if ($invalid.Count -eq 0) {
    if (-not $NoFileOutput -and (Test-Path -LiteralPath $OutputPath)) {
        Remove-Item -LiteralPath $OutputPath -Force
    }
    Write-Host "Semua file punya Snapshot-Content-Location valid di baris kedua."
    exit 0
}

Write-Host ''
Write-Host "File invalid:"
$invalid | Format-Table -AutoSize

if (-not $NoFileOutput) {
    $invalid | Export-Csv -LiteralPath $OutputPath -Delimiter "`t" -NoTypeInformation -Encoding UTF8
    Write-Host ''
    Write-Host "Output invalid: $OutputPath"
}

exit 1
