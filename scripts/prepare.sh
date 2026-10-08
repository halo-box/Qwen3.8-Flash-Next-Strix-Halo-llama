#!/usr/bin/env bash
# prepare.sh — get the engine image: pull the prebuilt one, else build it locally.
#
#   scripts/prepare.sh            pull, or build if the pull fails
#   scripts/prepare.sh --rebuild  build from scratch (PULL=0 does the same without --no-cache)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/config.sh

REBUILD=0; [[ "${1:-}" == --rebuild ]] && REBUILD=1

if ((!REBUILD)) && [[ "${PULL:-1}" == 1 ]] && docker pull "$IMAGE"; then
    docker tag "$IMAGE" "$LOCAL_IMAGE"
    echo "pulled $IMAGE"
    exit 0
fi

case "$BACKEND" in
    rocm)   BUILD=(-f docker/Dockerfile.rocm) ;;
    vulkan) BUILD=(-f docker/Dockerfile.vulkan) ;;
    *) echo "Error: BACKEND must be rocm or vulkan, got '$BACKEND'" >&2; exit 1 ;;
esac
BUILD+=(--build-arg "LLAMA_PRS=$LLAMA_PRS")
((REBUILD)) && BUILD+=(--no-cache)
echo "building $LOCAL_IMAGE (Vulkan: a few minutes; ROCm, which compiles its runtime: 5-60 min depending on cores)"
docker build -t "$LOCAL_IMAGE" "${BUILD[@]}" .
