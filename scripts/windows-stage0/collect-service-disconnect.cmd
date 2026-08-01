@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\collect.ps1" -ExpectedMode Service -DisconnectAfterReady
exit /b %errorlevel%
