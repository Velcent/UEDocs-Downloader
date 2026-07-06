Get-ChildItem -LiteralPath .\mhtml\EOS -Filter *.mhtml -Recurse -File | ForEach-Object {
    $path = $_.FullName
    $content = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    $content = $content -replace "=`r`n(?!`r`n)", ""
    $content = $content -replace "<!---->", ""
    $content = $content -replace "<iframe src", "<iframe allowfullscreen src"
    $content = $content -replace '
    (?sx)
    <aside.*?</aside>
    |<eos-navigation.*?</eos-navigation>
    |<epicgames-footer.*?</epicgames-footer>', ''
    Set-Content -LiteralPath $path -Value $content -ErrorAction Stop
}
