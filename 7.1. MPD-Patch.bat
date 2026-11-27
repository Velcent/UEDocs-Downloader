@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MPD-Patch.ps1" %*
