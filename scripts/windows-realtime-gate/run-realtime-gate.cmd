@echo off
setlocal
cd /d "%~dp0"
set "STORPULSE_SHELL_GATE_CONSOLE=1"

echo StorPulse Windows Stage 2C realtime collection gate
echo Running as the current user. UAC is not requested.
echo Close the WinUI window to keep collection running in the notification area.
echo Choose Exit StorPulse from the notification icon to stop the protocol and service.
echo.

start "" /wait "%~dp0StorPulse.Windows.App.exe"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
echo exit_code=%EXIT_CODE%
pause
exit /b %EXIT_CODE%
