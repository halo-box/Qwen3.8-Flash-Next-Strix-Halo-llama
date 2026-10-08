#!/usr/bin/env bash
# stop.sh — stop the server and free the GPU memory.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. scripts/config.sh
if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    docker stop -t "${STOP_TIMEOUT:-30}" "$CONTAINER_NAME" >/dev/null || true
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
    echo "stopped $CONTAINER_NAME"
else
    echo "not running"
fi
