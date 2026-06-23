@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0BP_API-Sync.ps1" %*

set "BP_API_SYNC_EXIT=%ERRORLEVEL%"
echo.
pause
exit /b %BP_API_SYNC_EXIT%
