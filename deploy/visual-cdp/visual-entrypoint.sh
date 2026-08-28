#!/bin/sh
set -eu

export DISPLAY=:99
mkdir -p /tmp/.X11-unix /app/data/profile

pids=""
cleanup() {
    for pid in $pids; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

start_component() {
    name="$1"
    shift
    echo "[start] $name: $*"
    "$@" &
    pid=$!
    pids="$pids $pid"
    echo "$pid" > "/tmp/${name}.pid"
}

require_alive() {
    name="$1"
    pid="$(cat "/tmp/${name}.pid")"
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "[fatal] $name exited during startup"
        exit 1
    fi
}

wait_tcp() {
    name="$1"
    port="$2"
    attempts="$3"
    i=1
    while [ "$i" -le "$attempts" ]; do
        require_alive "$name"
        if python3 - "$port" <<'PY'
import socket, sys
sock = socket.socket()
sock.settimeout(1)
try:
    sock.connect(('127.0.0.1', int(sys.argv[1])))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
PY
        then
            echo "[ready] $name is listening on $port"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    echo "[fatal] $name did not listen on $port within ${attempts}s"
    exit 1
}

start_component xvfb Xvfb :99 -screen 0 1280x800x24 -ac -nolisten tcp
sleep 1
require_alive xvfb

start_component openbox openbox
start_component x11vnc x11vnc -display :99 -localhost -forever -shared -rfbport 5900 -nopw
wait_tcp x11vnc 5900 30

start_component novnc python3 /usr/bin/websockify --web /opt/noVNC 6080 127.0.0.1:5900
wait_tcp novnc 6080 30

echo "[start] authenticated Chromium CDP proxy"
exec /usr/bin/node /app/proxy.js
