$TSVFile = "bp_api-list.tsv"
$RootPath = Get-Location

if (-not (Test-Path -LiteralPath $TSVFile)) {
    Write-Host "File tidak ditemukan: $TSVFile" -ForegroundColor Red
    exit
}

Write-Host "Checking: $TSVFile" -ForegroundColor Cyan

$LineNumber = 0

Get-Content -LiteralPath $TSVFile | ForEach-Object {

    $LineNumber++

    $Columns = $_ -split "`t"

    if ($Columns.Count -ge 3) {

        # kolom ke-3 = path mhtml
        $MhtmlPath = $Columns[2].Trim()

        if ($MhtmlPath -ne "") {

            $FullPath = Join-Path $RootPath $MhtmlPath

            if (-not (Test-Path -LiteralPath $FullPath)) {

                Write-Host "MISSING" -ForegroundColor Red
                Write-Host "File : $MhtmlPath"
                Write-Host "Line : $LineNumber"
                Write-Host ""
            }
        }
    }
}

Write-Host "Selesai."