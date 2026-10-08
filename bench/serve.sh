#!/usr/bin/env bash
# bench/serve.sh BACKEND [LABEL] — the recipe's own server under llama-benchy.
#
# Starts ./start.sh with the current settings (override any of them from the
# environment), runs llama-benchy at CONCURRENCY levels and saves
# results/serve/<BACKEND>[-LABEL].md and .json.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
BACKEND=${1:?usage: bench/serve.sh BACKEND [LABEL]}
export BACKEND LOCAL_IMAGE="qfn-strix:$BACKEND"
. scripts/config.sh
NAME=$BACKEND${2:+-$2}
: "${CONCURRENCY:=1 2 4 8}" "${PP:=2048}" "${TG:=256}" "${BENCH_DEPTHS:=0}" "${RUNS:=3}"
mkdir -p results/serve

./start.sh restart
{
    echo "# $NAME"
    echo "image: $(docker run --rm "$LOCAL_IMAGE" cat /opt/strix/versions.txt | paste -sd' ')"
    echo "settings: PARALLEL=$PARALLEL CONTEXT=$CONTEXT KV=$KV_DTYPE UB=$UBATCH MTP=$MTP N=$MTP_DRAFT_N SPEC=$SPEC_TYPE LAZY=$LAZY_MODE EXTRA='$EXTRA_ARGS'"
} > "results/serve/$NAME.md"

# shellcheck disable=SC2086
docker run --rm --network host -v "$PWD/results/serve:/out" local/llama-benchy:latest \
    --base-url "http://$HOST:$PORT/v1" --model "$SERVED_NAME" --tokenizer Qwen/Qwen3.8-Flash-Next \
    --pp $PP --tg $TG --depth $BENCH_DEPTHS --concurrency $CONCURRENCY --runs "$RUNS" \
    --no-cache --exact-tg --format json --save-result "/out/$NAME.json" \
    | tee -a "results/serve/$NAME.md"
{ echo "draft acceptance, last requests:"; docker logs "$CONTAINER_NAME" 2>&1 | grep -oE 'draft acceptance = [0-9.]+' | tail -5; } >> "results/serve/$NAME.md" || true
./stop.sh
