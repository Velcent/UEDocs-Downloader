Get-ChildItem -LiteralPath .\mhtml -Filter *.mhtml -Recurse -File | ForEach-Object {
    $path = $_.FullName
    $content = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    $content = $content -replace "=`r`n(?!`r`n)", ""
    $content = $content -replace "<!---->", ""
    $content = $content -replace "<iframe src", "<iframe allowfullscreen src"
    $content = $content -replace '(?sx)
    <div\s+id=3D"top"></div>
    |<source\b.*?>
    |<site-header\b.*?</site-header>
    |<side-panel\b.*?</side-panel>
    |<site-modal\b.*?</site-modal>
    |<notify-component\b.*?</notify-component>
    |<hot-toast-container\b.*?</hot-toast-container>
    |<site-nav\b.*?</site-nav>
    |<site-footer\b.*?</site-footer>', ''
    Set-Content -LiteralPath $path -Value $content -ErrorAction Stop
}
