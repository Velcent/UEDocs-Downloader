@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0BP_API-Downloader.ps1" %*
