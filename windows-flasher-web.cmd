@echo off
setlocal
cd /d "%~dp0"

set "FL_HOST=0.0.0.0"
set "FL_PORT=1111"
set "FL_URL=http://127.0.0.1:%FL_PORT%/"

echo [8bb-flasher] Starting backend on %FL_HOST%:%FL_PORT%
start "8bb Flasher Backend" cmd /k ""%~dp0run.cmd" --mode backend --host %FL_HOST% --port %FL_PORT%"

echo [8bb-flasher] Waiting for backend, then opening %FL_URL%
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$url='%FL_URL%';" ^
  "$deadline=(Get-Date).AddSeconds(20);" ^
  "while((Get-Date) -lt $deadline){" ^
  "  try { $r=Invoke-WebRequest -UseBasicParsing -Uri ($url + 'api/auth/status') -TimeoutSec 2; if($r.StatusCode -ge 200){ break } } catch {};" ^
  "  Start-Sleep -Milliseconds 700" ^
  "};" ^
  "Start-Process $url"

endlocal
