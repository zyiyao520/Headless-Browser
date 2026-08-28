#!/usr/bin/env bash
set -Eeuo pipefail

export DISPLAY="${DISPLAY:-:99}"
SCREEN_WIDTH="${SCREEN_WIDTH:-1280}"
SCREEN_HEIGHT="${SCREEN_HEIGHT:-800}"
SCREEN_DEPTH="${SCREEN_DEPTH:-24}"
VNC_PORT="${VNC_PORT:-5901}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
CDP_PORT="${CDP_PORT:-9222}"
CLOAK_IDLE_TIMEOUT="${CLOAK_IDLE_TIMEOUT:-300}"
CLOAK_DATA_DIR="${CLOAK_DATA_DIR:-/data/profile}"

mkdir -p "$CLOAK_DATA_DIR" /data/downloads /data/screenshots /data/logs /run/browser-stack
pids=()

start_bg() {
  local name="$1"
  shift
  echo "[start] $name"
  "$@" >"/data/logs/${name}.log" 2>&1 &
  local pid=$!
  pids+=("$pid")
  printf '%s\n' "$pid" >"/run/browser-stack/${name}.pid"
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  echo "[stop] shutting down browser stack"
  for pid in "${pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT INT TERM

start_bg xvfb Xvfb "$DISPLAY" -screen 0 "${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}" -nolisten tcp -ac
for _ in $(seq 1 100); do
  xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
  sleep 0.1
done
xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 || { echo "[fatal] Xvfb failed"; exit 1; }

start_bg openbox openbox

VNC_ARGS=(-display "$DISPLAY" -localhost -forever -shared -rfbport "$VNC_PORT")
if [[ -n "${VNC_PASSWORD:-}" ]]; then
  x11vnc -storepasswd "$VNC_PASSWORD" /run/browser-stack/vnc.pass >/dev/null
  chmod 0600 /run/browser-stack/vnc.pass
  VNC_ARGS+=(-rfbauth /run/browser-stack/vnc.pass)
else
  echo "[warn] VNC_PASSWORD is unset; rely on HTTPS edge authentication"
  VNC_ARGS+=(-nopw)
fi
start_bg x11vnc x11vnc "${VNC_ARGS[@]}"

start_bg novnc websockify --web /usr/share/novnc "$NOVNC_PORT" "127.0.0.1:${VNC_PORT}"

# cloakserve only consumes its own options in --name=value form. Passing
# "--port 9222" leaves "9222" as a positional Chrome target and makes Chrome
# abort with "Multiple targets are not supported in headless mode".
# The official container automatically listens on 0.0.0.0.
CLOAK_ARGS=(
  "--port=${CDP_PORT}"
  "--headless=false"
  "--idle-timeout=${CLOAK_IDLE_TIMEOUT}"
  "--data-dir=${CLOAK_DATA_DIR}"
  "--disable-dev-shm-usage"
)
start_bg cloakserve cloakserve "${CLOAK_ARGS[@]}"

# First boot downloads and extracts the CloakBrowser Chromium payload. On a
# cold GitHub runner or cloud VM this can take several minutes, so do not fail
# the whole stack after the previous 60-second window.
CDP_READY=0
for attempt in $(seq 1 180); do
  if curl --connect-timeout 2 --max-time 5 -fsS \
      "http://127.0.0.1:${CDP_PORT}/json/version" >/dev/null 2>&1; then
    CDP_READY=1
    break
  fi
  if (( attempt % 12 == 0 )); then
    echo "[wait] CloakBrowser first-start initialization: attempt ${attempt}/180"
    tail -n 30 /data/logs/cloakserve.log 2>/dev/null || true
  fi
  sleep 5
done

if (( CDP_READY == 0 )); then
  echo "[fatal] CloakBrowser CDP did not become ready within 15 minutes"
  cat /data/logs/cloakserve.log 2>/dev/null || true
  exit 1
fi

/usr/local/bin/browser-stack-healthcheck
echo "[ready] noVNC=:${NOVNC_PORT}, CDP=127.0.0.1:${CDP_PORT}, display=${DISPLAY}"

while sleep 2; do
  for pid in "${pids[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "[fatal] child process $pid exited"
      exit 1
    fi
  done
done
