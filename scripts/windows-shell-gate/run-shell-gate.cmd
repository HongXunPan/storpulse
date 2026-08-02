@echo off
setlocal
cd /d "%~dp0"
set "STORPULSE_SHELL_GATE_CONSOLE=1"

echo StorPulse Windows Stage 2B WinUI lifecycle gate
echo Running as the current user. UAC is not requested.
echo Close the WinUI window to keep the app in the notification area.
echo Reopen it from the notification icon, then choose Exit StorPulse to return here.
echo.

start "" /wait "%~dp0StorPulse.Windows.App.exe"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
echo exit_code=%EXIT_CODE%
pause
exit /b %EXIT_CODE%
