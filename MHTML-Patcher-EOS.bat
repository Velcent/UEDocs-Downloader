@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MHTML-Patcher-EOS.ps1" %*
