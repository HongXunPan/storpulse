@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\collect.ps1" -StageName windows-stage1-connect-timeout-cleanup -NoPause
set "exit_code=%errorlevel%"
echo exit_code=%exit_code%
pause
exit /b %exit_code%
