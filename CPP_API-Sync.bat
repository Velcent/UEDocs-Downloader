@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CPP_API-Sync.ps1" %*

set "CPP_API_SYNC_EXIT=%ERRORLEVEL%"
echo.
pause
exit /b %CPP_API_SYNC_EXIT%
