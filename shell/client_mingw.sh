#!/bin/bash
# Windows 终端测试客户端（Git Bash / Wine 下运行 mingw 编译的 lua.exe）
cd "$(dirname "$0")/.."
export CLIENT_CPATH="bin/win/luaclib/?.so"
exec ./3rd/lua/lua.exe client/main.lua
