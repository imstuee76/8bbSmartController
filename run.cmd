@echo off
setlocal
cd /d "%~dp0"

where python >nul 2>nul
if %errorlevel%==0 (
  python run.py %*
  exit /b %errorlevel%
)

if exist "C:\Program Files\Python313\python.exe" (
  "C:\Program Files\Python313\python.exe" run.py %*
  exit /b %errorlevel%
)

if exist "%LocalAppData%\Programs\Python\Python313\python.exe" (
  "%LocalAppData%\Programs\Python\Python313\python.exe" run.py %*
  exit /b %errorlevel%
)

where py >nul 2>nul
if %errorlevel%==0 (
  py -3 run.py %*
  exit /b %errorlevel%
)

echo [8bb-run] ERROR: Python is not available in PATH.
exit /b 1
