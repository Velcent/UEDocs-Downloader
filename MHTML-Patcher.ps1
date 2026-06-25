Get-ChildItem -LiteralPath .\mhtml -Filter *.mhtml -Recurse -File | ForEach-Object {
    $path = $_.FullName
    $content = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    $content = $content -replace "=`r`n(?!`r`n)", ""
    $content = $content -replace "<!---->", ""
    $content = $content -replace "<iframe src", "<iframe allowfullscreen src"
    $content = $content -replace '
    (?sx)
    <div id=3D"top"></div>
    |<source.*?>
    |<site-header.*?</site-header>
    |<side-panel.*?</side-panel>
    |<site-modal.*?</site-modal>
    |<notify-component.*?</notify-component>
    |<hot-toast-container.*?</hot-toast-container>
    |<site-nav.*?</site-nav>
    |<site-footer.*?</site-footer>', ''
    Set-Content -LiteralPath $path -Value $content -ErrorAction Stop
}
