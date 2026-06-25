@echo off
setlocal EnableDelayedExpansion

set "TARGET_DIR=mhtml"

for /r "%TARGET_DIR%" %%F in (*.mhtml) do (
    echo Processing: %%F

    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$file='%%F';" ^
    "$content=[IO.File]::ReadAllText($file);" ^
    "$q=[char]34;" ^
    "$m=[regex]::Match($content,'boundary='+$q+'([^'+$q+']+)'+$q);" ^
    "if($m.Success) {" ^
        "$boundary=[regex]::Escape($m.Groups[1].Value);" ^
        "$pattern='(?s)\r?\n*--'+$boundary+'-*\s*\r?\nContent-Type:\s*image/.*?(?=\r?\n--'+$boundary+'|$)';" ^
        "$result=[regex]::Replace($content,$pattern,'');" ^
        "$result=[regex]::Replace($result,'(\r?\n){3,}',[Environment]::NewLine+[Environment]::NewLine);" ^
        "[IO.File]::WriteAllText($file,$result);" ^
        "Write-Host 'Images removed';" ^
    "} else { Write-Host 'Boundary tidak ditemukan' }"
)

echo.
echo Selesai.
pause