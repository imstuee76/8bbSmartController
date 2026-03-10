@echo off
setlocal
cd /d "%~dp0"

call "%~dp0run.cmd" --mode backend --host 0.0.0.0 --port 1111 %*
exit /b %errorlevel%
