@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\collect.ps1" -ExpectedMode Standard -StageName standard-collection
exit /b %errorlevel%
