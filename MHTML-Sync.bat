@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MHTML-Sync.ps1" %*

set "MHTML_SYNC_EXIT=%ERRORLEVEL%"
echo.
pause
exit /b %MHTML_SYNC_EXIT%
