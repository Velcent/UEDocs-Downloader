@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0WEB-Downloader.ps1" %*
