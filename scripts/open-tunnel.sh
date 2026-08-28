#!/usr/bin/env bash
set -Eeuo pipefail
: "${UKC_TOKEN:?Set UKC_TOKEN}"
UKC_METRO="${UKC_METRO:-fra}"
INSTANCE_NAME="${UKC_INSTANCE_NAME:-cloak-browser}"
LOCAL_PORT="${LOCAL_CDP_PORT:-9222}"
exec kraft cloud tunnel --metro "$UKC_METRO" --token "$UKC_TOKEN" "${LOCAL_PORT}:${INSTANCE_NAME}:9222/tcp"
