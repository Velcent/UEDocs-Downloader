[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$TargetDir = (Join-Path $PSScriptRoot 'mhtml'),

    [Alias('ThrottleLimit')]
    [int]$Parallel = 0,

    [int]$BatchSize = 0,

    [switch]$VerboseFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [System.IO.Path]::IsPathRooted($TargetDir)) {
    $TargetDir = Join-Path $PSScriptRoot $TargetDir
}

$TargetDir = [System.IO.Path]::GetFullPath($TargetDir)

if (-not (Test-Path -LiteralPath $TargetDir -PathType Container)) {
    throw "Folder tidak ditemukan: $TargetDir"
}

$timer = [System.Diagnostics.Stopwatch]::StartNew()

if ($Parallel -lt 1) {
    $Parallel = [Environment]::ProcessorCount
}

if ($Parallel -lt 1) {
    $Parallel = 1
}

$filePaths = [string[]]@(Get-ChildItem -LiteralPath $TargetDir -Recurse -File -Filter '*.mhtml' | ForEach-Object { $_.FullName })
$fileCount = $filePaths.Count

if ($fileCount -eq 0) {
    Write-Host "Tidak ada file .mhtml di: $TargetDir"
    exit 0
}

$workerCount = [Math]::Min($Parallel, $fileCount)

if ($BatchSize -lt 1) {
    $targetBatchCount = [Math]::Max($workerCount, $workerCount * 8)
    $BatchSize = [Math]::Max(1, [int][Math]::Ceiling($fileCount / [double]$targetBatchCount))
}

function New-PathBatches {
    param(
        [string[]]$Paths,
        [int]$Size
    )

    for ($index = 0; $index -lt $Paths.Count; $index += $Size) {
        $end = [Math]::Min($index + $Size - 1, $Paths.Count - 1)
        ,([string[]]$Paths[$index..$end])
    }
}

$workerScript = {
    param([string[]]$Paths)

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    function Remove-MhtmlImageParts {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Path
        )

        $content = [System.IO.File]::ReadAllText($Path)
        $boundaryMatch = [regex]::Match(
            $content,
            'boundary=(?:"(?<quoted>[^"]+)"|(?<plain>[^;\r\n\s]+))',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if (-not $boundaryMatch.Success) {
            return [pscustomobject]@{
                Removed = 0
                Status = 'Boundary tidak ditemukan'
            }
        }

        $boundary = if ($boundaryMatch.Groups['quoted'].Success) {
            $boundaryMatch.Groups['quoted'].Value
        } else {
            $boundaryMatch.Groups['plain'].Value
        }

        $escapedBoundary = [regex]::Escape($boundary)
        $partPattern = "(?ms)(?:\r?\n)?^--$escapedBoundary\r?\n(?<headers>.*?\r?\n\r?\n)(?<body>.*?)(?=^--$escapedBoundary(?:--)?[ \t]*(?:\r?\n|$))"
        $state = [pscustomobject]@{ Removed = 0 }

        $result = [regex]::Replace($content, $partPattern, {
            param($match)

            $headers = $match.Groups['headers'].Value
            $isImagePart = $headers -match '(?im)^Content-Type:\s*image/'
            $isHttpLocation = $headers -match '(?im)^Content-Location:\s*<?https?://'

            if ($isImagePart -and $isHttpLocation) {
                $state.Removed++
                return ''
            }

            return $match.Value
        })

        if ($state.Removed -gt 0 -and $result -ne $content) {
            $result = [regex]::Replace($result, '(\r?\n){3,}', [Environment]::NewLine + [Environment]::NewLine)
            [System.IO.File]::WriteAllText($Path, $result)
        }

        return [pscustomobject]@{
            Removed = $state.Removed
            Status = if ($state.Removed -gt 0) { "HTTP images removed: $($state.Removed)" } else { 'Tidak ada HTTP image part' }
        }
    }

    foreach ($path in $Paths) {
        try {
            $result = Remove-MhtmlImageParts -Path $path

            [pscustomobject]@{
                Path = $path
                Success = $true
                Removed = [int]$result.Removed
                Status = [string]$result.Status
                Error = ''
            }
        } catch {
            [pscustomobject]@{
                Path = $path
                Success = $false
                Removed = 0
                Status = 'Gagal'
                Error = $_.Exception.Message
            }
        }
    }
}

function Add-BatchResults {
    param(
        [object[]]$BatchResults,
        [System.Collections.Generic.List[object]]$Results
    )

    foreach ($result in $BatchResults) {
        [void]$Results.Add($result)

        if ($VerboseFiles) {
            if ($result.Success) {
                Write-Host "$($result.Status): $($result.Path)"
            } else {
                Write-Warning "Gagal memproses $($result.Path): $($result.Error)"
            }
        } elseif (-not $result.Success) {
            Write-Warning "Gagal memproses $($result.Path): $($result.Error)"
        }
    }
}

function Write-ProgressLine {
    param(
        [int]$Completed,
        [int]$Total,
        [ref]$NextPercent
    )

    $percent = [int][Math]::Floor(($Completed * 100.0) / $Total)

    if ($Completed -eq $Total -or $percent -ge $NextPercent.Value) {
        Write-Host "Progress: $Completed/$Total ($percent%)"

        while ($NextPercent.Value -le $percent) {
            $NextPercent.Value += 10
        }
    }
}

$batches = @(New-PathBatches -Paths $filePaths -Size $BatchSize)
$results = New-Object 'System.Collections.Generic.List[object]'
$completed = 0
$nextPercent = 10

Write-Host "Target  : $TargetDir"
Write-Host "File    : $fileCount"
Write-Host "Parallel: $workerCount"
Write-Host "Batch   : $($batches.Count) x up to $BatchSize file"

if ($workerCount -le 1) {
    foreach ($batch in $batches) {
        $batchResults = @(& $workerScript $batch)
        Add-BatchResults -BatchResults $batchResults -Results $results
        $completed += $batch.Count
        Write-ProgressLine -Completed $completed -Total $fileCount -NextPercent ([ref]$nextPercent)
    }
} else {
    $runspacePool = $null
    $jobs = New-Object 'System.Collections.Generic.List[object]'

    try {
        $runspacePool = [runspacefactory]::CreateRunspacePool(1, $workerCount)
        $runspacePool.Open()

        foreach ($batch in $batches) {
            $powershell = [powershell]::Create()
            $powershell.RunspacePool = $runspacePool
            [void]$powershell.AddScript($workerScript.ToString()).AddArgument($batch)

            [void]$jobs.Add([pscustomobject]@{
                PowerShell = $powershell
                Handle = $powershell.BeginInvoke()
                Count = $batch.Count
                Paths = $batch
            })
        }

        while ($jobs.Count -gt 0) {
            for ($index = $jobs.Count - 1; $index -ge 0; $index--) {
                $job = $jobs[$index]

                if (-not $job.Handle.IsCompleted) {
                    continue
                }

                try {
                    $batchResults = @($job.PowerShell.EndInvoke($job.Handle))
                    Add-BatchResults -BatchResults $batchResults -Results $results

                    foreach ($errorRecord in @($job.PowerShell.Streams.Error)) {
                        Write-Warning "Worker error: $errorRecord"
                    }
                } catch {
                    Write-Warning "Worker gagal: $($_.Exception.Message)"

                    foreach ($path in $job.Paths) {
                        [void]$results.Add([pscustomobject]@{
                            Path = $path
                            Success = $false
                            Removed = 0
                            Status = 'Gagal'
                            Error = $_.Exception.Message
                        })
                    }
                } finally {
                    $job.PowerShell.Dispose()
                    $completed += $job.Count
                    Write-ProgressLine -Completed $completed -Total $fileCount -NextPercent ([ref]$nextPercent)
                    $jobs.RemoveAt($index)
                }
            }

            if ($jobs.Count -gt 0) {
                Start-Sleep -Milliseconds 80
            }
        }
    } finally {
        for ($index = $jobs.Count - 1; $index -ge 0; $index--) {
            $job = $jobs[$index]

            if ($null -ne $job.PowerShell) {
                $job.PowerShell.Dispose()
            }
        }

        if ($null -ne $runspacePool) {
            $runspacePool.Close()
            $runspacePool.Dispose()
        }
    }
}

$timer.Stop()
$totalRemoved = 0
$changedFiles = 0
$failedFiles = 0

foreach ($result in $results) {
    if (-not $result.Success) {
        $failedFiles++
        continue
    }

    $totalRemoved += $result.Removed

    if ($result.Removed -gt 0) {
        $changedFiles++
    }
}

Write-Host ''
Write-Host "Selesai."
Write-Host "File diproses      : $fileCount"
Write-Host "File berubah       : $changedFiles"
Write-Host "HTTP image dihapus : $totalRemoved"
Write-Host "Gagal              : $failedFiles"
Write-Host "Durasi             : $($timer.Elapsed.ToString('hh\:mm\:ss'))"
