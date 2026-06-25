@echo off
REM Windows 原生运行脚本（在 Windows 上直接双击或命令行运行）
cd /d "%~dp0\.."
taskkill /f /im skynet.exe 2>nul
timeout /t 1 /nobreak >nul
bin\win\skynet.exe
