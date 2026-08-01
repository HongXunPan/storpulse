@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

echo StorPulse Windows 阶段 2A WinUI 界面门禁
echo 当前入口保持标准用户权限，不请求 UAC。
echo 关闭 WinUI 窗口后，本窗口会显示退出码。
echo.

start "" /wait "%~dp0StorPulse.Windows.App.exe"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
echo exit_code=%EXIT_CODE%
pause
exit /b %EXIT_CODE%
