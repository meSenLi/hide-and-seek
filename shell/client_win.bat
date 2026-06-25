@echo off
REM Windows 原生终端测试客户端
cd /d "%~dp0\.."
set CLIENT_CPATH=bin/win/luaclib/?.so
3rd\lua\lua.exe client\main.lua
