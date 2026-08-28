#!/usr/bin/env bash
set -Eeuo pipefail
CDP_PORT="${CDP_PORT:-9222}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
curl --connect-timeout 2 --max-time 5 -fsS "http://127.0.0.1:${CDP_PORT}/json/version" >/dev/null
curl --connect-timeout 2 --max-time 5 -fsS "http://127.0.0.1:${NOVNC_PORT}/vnc.html" >/dev/null
