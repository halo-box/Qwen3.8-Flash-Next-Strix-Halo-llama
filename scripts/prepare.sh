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
    vulkan)       BUILD=(-f docker/Dockerfile.vulkan) ;;
    rocm10.1)     BUILD=(-f docker/Dockerfile.rocm --build-arg ROCM_VERSION=10.1 --build-arg PM4=0) ;;
    rocm10.1-pm4) BUILD=(-f docker/Dockerfile.rocm --build-arg ROCM_VERSION=10.1 --build-arg PM4=1) ;;
    rocm10.0-pm4) BUILD=(-f docker/Dockerfile.rocm --build-arg ROCM_VERSION=10.0 --build-arg PM4=1) ;;
    *) echo "Error: unknown BACKEND '$BACKEND'" >&2; exit 1 ;;
esac
((REBUILD)) && BUILD+=(--no-cache)
echo "building $LOCAL_IMAGE (Vulkan: ~5 min; ROCm with PM4: 40-60 min)"
docker build -t "$LOCAL_IMAGE" "${BUILD[@]}" .
