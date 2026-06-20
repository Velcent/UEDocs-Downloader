$Files = Get-ChildItem -Path . -Filter *.tsv -Recurse

foreach ($File in $Files) {

    Write-Host "`nChecking: $($File.FullName)" -ForegroundColor Cyan

    $Duplicates = Get-Content -LiteralPath $File.FullName |
        ForEach-Object {

            # ambil kolom pertama sebelum TAB
            ($_ -split "`t")[2].Trim()

        } |
        Where-Object { $_ -ne "" } |
        Group-Object |
        Where-Object { $_.Count -gt 1 }


    if ($Duplicates) {

        Write-Host "Duplicate found:" -ForegroundColor Yellow

        foreach ($Dup in $Duplicates) {

            Write-Host ""
            Write-Host "Link: $($Dup.Name)" -ForegroundColor Red
            Write-Host "Jumlah: $($Dup.Count)" -ForegroundColor DarkYellow

            # print semua baris yang punya link tersebut
            Get-Content -LiteralPath $File.FullName |
                Where-Object {
                    ($_ -split "`t")[0].Trim() -eq $Dup.Name
                } |
                ForEach-Object {
                    Write-Host $_
                }
        }

    }
    else {
        Write-Host "Tidak ada duplicate"
    }
}