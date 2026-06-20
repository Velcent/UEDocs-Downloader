$SearchText = "One more step.mhtml"

$Files = Get-ChildItem -Path . -Filter *.tsv -Recurse |
         Where-Object { $_.Name -notlike "*.tmp" }

foreach ($Item in $Files) {

    $File = $Item.FullName
    $TempFile = "$File.tmp"

    Write-Host "Processing: $File"

    Get-Content -LiteralPath $File |
        Where-Object { $_ -notmatch [regex]::Escape($SearchText) } |
        Set-Content -LiteralPath $TempFile -Encoding UTF8

    Move-Item -LiteralPath $TempFile -Destination $File -Force
}

Write-Host ""
Write-Host "Selesai."
pause