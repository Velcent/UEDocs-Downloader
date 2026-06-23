Get-ChildItem -Path . -Filter *.mhtml -Recurse | ForEach-Object {
    $content = Get-Content $_.FullName -Raw
    $content = $content -replace "=`r`n(?!`r`n)", ""
    $content = $content -replace '
    (?sx)
    <div id=3D"top"></div>
    |<site-header.*?</site-header>
    |<side-panel.*?</side-panel>
    |<site-modal.*?</site-modal>
    |<notify-component.*?</notify-component>
    |<hot-toast-container.*?</hot-toast-container>
    |<site-nav.*?</site-nav>
    |<site-footer.*?</site-footer>', ''
    Set-Content $_.FullName $content
}