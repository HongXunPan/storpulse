@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\launch-service-install.ps1"
set "exit_code=%errorlevel%"
echo exit_code=%exit_code%
pause
exit /b %exit_code%
