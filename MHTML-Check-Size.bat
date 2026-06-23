@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MHTML-Check-Size.ps1" %*

echo.
echo Selesai. Tekan tombol apa saja untuk menutup...
pause >nul
