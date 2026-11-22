@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CPP_API-Downloader.ps1" %*

