@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\collect.ps1" -ExpectedMode PerformanceLogUser -StageName performance-log-user-collection
exit /b %errorlevel%
