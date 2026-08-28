#!/bin/sh
set -eu
export DISPLAY=:99
mkdir -p /tmp/.X11-unix /data/profile
Xvfb :99 -screen 0 1280x800x24 -ac -nolisten tcp > /tmp/xvfb.log 2>&1 &
sleep 1
openbox > /tmp/openbox.log 2>&1 &
x11vnc -display :99 -localhost -forever -shared -rfbport 5900 -nopw > /tmp/x11vnc.log 2>&1 &
python3 /usr/bin/websockify --web /opt/noVNC 6080 127.0.0.1:5900 > /tmp/novnc.log 2>&1 &
exec /usr/bin/node /app/proxy.js
