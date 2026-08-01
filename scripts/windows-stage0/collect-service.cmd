@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\collect.ps1" -ExpectedMode Service -StageName service-collection
exit /b %errorlevel%
