#!/usr/bin/env bash
# bench/kernel.sh BACKEND — raw prefill/decode with llama-bench (no server, no MTP).
#
# Writes results/kernel/<BACKEND>.jsonl. Depths and ubatch sizes can be
# overridden: DEPTHS=0,32768 UBATCHES=512,2048 bench/kernel.sh vulkan
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
BACKEND=${1:?usage: bench/kernel.sh BACKEND}
. scripts/config.sh
: "${DEPTHS:=0,32768}" "${UBATCHES:=512,2048}" "${REPS:=3}"

DEV=(--device /dev/dri); [[ "$BACKEND" == rocm* ]] && DEV+=(--device /dev/kfd)
mkdir -p results/kernel
docker run --rm "${DEV[@]}" --group-add "$(getent group render | cut -d: -f3)" \
    --ipc=host --security-opt seccomp=unconfined -v "$MODEL_DIR:/models:ro" \
    $(compgen -e | grep -E '^(GGML_|HIP_|AMD_|HSA_|RADV_)' | sed 's/^/-e /') \
    "$LOCAL_IMAGE" llama-bench -m "/models/$MODEL_FILE" \
    -ngl 999 -fa on -ctk "$KV_DTYPE" -ctv "$KV_DTYPE" -lm "$LOAD_MODE" -lzm "$LAZY_MODE" \
    -p 2048 -n 128 -d "$DEPTHS" -b 2048 -ub "$UBATCHES" -r "$REPS" -o jsonl \
    | tee "results/kernel/$BACKEND.jsonl"
