@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MPD-Downloader.ps1" %*
