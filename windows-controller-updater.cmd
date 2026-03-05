@echo off
setlocal
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows-controller-updater.ps1" %*
exit /b %errorlevel%

