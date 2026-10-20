#!/bin/bash
# Launch Victor Net (menu bar network icon, test hooks on 127.0.0.1:55126).
LOG=/tmp/victor-net.log
APP="/Applications/Victor Net.app"
echo "$(date '+%H:%M:%S') Starting Victor Net..." >> "$LOG"
if [ ! -x "$APP/Contents/MacOS/Victor Net" ]; then
    echo "$(date '+%H:%M:%S') Victor Net not installed — run: ./build-app.sh" >> "$LOG"
    exit 1
fi
# `open`, never the bundle binary: macOS files a process that exec'd its own
# Mach-O by path, as a second app with the same name.
exec /usr/bin/open -a "$APP"
