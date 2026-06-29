[CmdletBinding()]
param(
    [string]$InputRoot = '',
    [string]$OutputRoot = '',
    [string[]]$Extensions = @('.jpg', '.jpeg', '.png', '.gif', '.webp', '.svg'),
    [switch]$OverwriteExistingOutput,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $InputRoot) {
    $InputRoot = Join-Path $PSScriptRoot 'assets\bin'
}

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $PSScriptRoot 'assets\img'
}

$InputRoot = [System.IO.Path]::GetFullPath($InputRoot)
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)

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

function Invoke-OptimiztFile {
    param(
        [System.IO.FileInfo]$File,
        [string]$TargetDirectory
    )

    $arguments = New-Object System.Collections.Generic.List[string]
    if ($File.Extension -ieq '.gif') {
        $arguments.Add('-l') | Out-Null
    }

    $arguments.Add('-o') | Out-Null
    $arguments.Add($TargetDirectory) | Out-Null
    $arguments.Add($File.FullName) | Out-Null

    if ($WhatIf) {
        Write-Host "WHATIF optimizt $($arguments -join ' ')"
        return 0
    }

    & optimizt @arguments | ForEach-Object {
        Write-Host $_
    }

    return [int]$global:LASTEXITCODE
}

$optimiztCommand = Get-Command 'optimizt' -ErrorAction SilentlyContinue
if (-not $optimiztCommand) {
    throw 'optimizt tidak ditemukan di PATH.'
}

if (-not (Test-Path -LiteralPath $InputRoot)) {
    throw "InputRoot tidak ditemukan: $InputRoot"
}

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

$extensionSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($extension in $Extensions) {
    if ([string]::IsNullOrWhiteSpace($extension)) {
        continue
    }

    $value = $extension.Trim().ToLowerInvariant()
    if ($value[0] -ne '.') {
        $value = ".$value"
    }

    [void]$extensionSet.Add($value)
}

$assetItems = New-Object System.Collections.Generic.List[object]
foreach ($file in @(Get-ChildItem -LiteralPath $InputRoot -Recurse -File)) {
    $extension = $file.Extension.ToLowerInvariant()
    if (-not $extensionSet.Contains($extension)) {
        continue
    }

    $relativePath = Get-RelativePathFromBase -BasePath $InputRoot -FullPath $file.FullName
    $assetItems.Add([pscustomobject]@{
        File = $file
        RelativePath = $relativePath
        OutputRelativePath = $relativePath
        Extension = $extension
    }) | Out-Null
}

$optimized = 0
$skippedExisting = 0
$skippedNoOutput = 0
$failed = 0

Write-Host "Optimizt command : $($optimiztCommand.Source)"
Write-Host "Input assets    : $InputRoot"
Write-Host "Output images   : $OutputRoot"
Write-Host "Image files     : $($assetItems.Count)"

foreach ($item in $assetItems) {
    $file = [System.IO.FileInfo]$item.File
    $relativePath = [string]$item.RelativePath
    $targetPath = Join-Path $OutputRoot ([string]$item.OutputRelativePath)
    $targetDirectory = Split-Path -Parent $targetPath
    $inputFile = $file

    if (-not $OverwriteExistingOutput -and (Test-Path -LiteralPath $targetPath)) {
        $skippedExisting++
        continue
    }

    New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null

    if ($OverwriteExistingOutput -and (Test-Path -LiteralPath $targetPath) -and -not $WhatIf) {
        Remove-Item -LiteralPath $targetPath -Force
    }

    $mode = if ([string]$item.Extension -ieq '.gif') { 'lossless gif' } else { 'default' }
    Write-Host "Optimize [$mode]: $relativePath"

    try {
        $exitCode = Invoke-OptimiztFile -File $inputFile -TargetDirectory $targetDirectory
        if ($exitCode -ne 0) {
            throw "optimizt exit code $exitCode"
        }

        if ($WhatIf) {
            continue
        }

        if (Test-Path -LiteralPath $targetPath) {
            $optimized++
        }
        else {
            $skippedNoOutput++
            Write-Host "Skip output     : $relativePath (optimizt tidak membuat output, biasanya karena hasil lebih besar dari file asli)"
        }
    }
    catch {
        $failed++
        Write-Warning "Gagal optimizt $relativePath - $($_.Exception.Message)"
    }
}

Write-Host ''
Write-Host 'Done.'
Write-Host "Input images          : $($assetItems.Count)"
Write-Host "Optimized outputs     : $optimized"
Write-Host "Skipped existing      : $skippedExisting"
Write-Host "Skipped no output     : $skippedNoOutput"
Write-Host "Failed                : $failed"
Write-Host "Output folder         : $OutputRoot"
pause
