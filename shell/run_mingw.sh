#!/bin/bash
# 运行 Windows 版本（通过 Wine）或原生 Windows（Git Bash 下）
fuser -k 8000/tcp &>/dev/null
fuser -k 8888/tcp &>/dev/null
pkill -9 -f bin/win/skynet &>/dev/null
sleep 1
cd "$(dirname "$0")/.." && exec ./bin/win/skynet.exe
