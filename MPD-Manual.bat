@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "MPD_DIR=%~dp0video\mpd"
set "MP4_DIR=%~dp0video\mp4"

if not exist "%MP4_DIR%" mkdir "%MP4_DIR%"

for %%F in ("%MPD_DIR%\*.mpd") do (
    set "MPD_FILE=%%~fF"
    set "MPD_URL=file:///!MPD_FILE:\=/!"
    set "OUTPUT_FILE=%MP4_DIR%\%%~nF.mp4"

    if exist "!OUTPUT_FILE!" (
        echo Skipping %%~nxF because %%~nF.mp4 already exists
    ) else (
        echo Downloading %%~nxF to %%~nF.mp4
        yt-dlp --enable-file-urls ^
            "!MPD_URL!" ^
            -f "bestvideo[height<=720]+bestaudio/best[height<=720]" ^
            --merge-output-format mp4 ^
            -o "%MP4_DIR%\%%~nF.%%(ext)s"
    )
)

echo Done.
pause
