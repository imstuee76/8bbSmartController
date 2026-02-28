@echo off
setlocal
cd /d "%~dp0"

where python >nul 2>nul
if %errorlevel%==0 (
  python git_push.py %*
  exit /b %errorlevel%
)

where py >nul 2>nul
if %errorlevel%==0 (
  py -3 git_push.py %*
  exit /b %errorlevel%
)

echo [8bb-git] ERROR: Python was not found in PATH.
exit /b 1
