@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0XML-Downloader.ps1" %*
