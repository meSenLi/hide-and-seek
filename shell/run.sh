#!/bin/bash
fuser -k 8000/tcp &>/dev/null
fuser -k 8888/tcp &>/dev/null
pkill -9 -f bin/linux/skynet &>/dev/null
sleep 1
cd "$(dirname "$0")/.." && exec bin/linux/skynet