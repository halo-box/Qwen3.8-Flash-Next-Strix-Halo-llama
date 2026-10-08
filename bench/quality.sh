#!/usr/bin/env bash
# bench/quality.sh BACKEND — correctness gate before any speed number counts.
#
# 1. Perplexity on wikitext-2 (first CHUNKS chunks of 2048 tokens).
# 2. Greedy consistency: the same prompt answered alone and by PARALLEL concurrent
#    requests through the recipe's own server must give the same text. This is the
#    check that catches the gfx1151 HIP async bug (strix-llama.cpp README).
# Writes results/quality/<BACKEND>.txt.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
BACKEND=${1:?usage: bench/quality.sh BACKEND}
export BACKEND LOCAL_IMAGE="qfn-strix:$BACKEND"
. scripts/config.sh
: "${CHUNKS:=40}"
OUT=results/quality/$BACKEND.txt
mkdir -p results/quality bench/data

if [[ ! -f bench/data/wiki.test.raw ]]; then
    curl -sL -o /tmp/wikitext-2-raw-v1.zip https://huggingface.co/datasets/ggml-org/ci/resolve/main/wikitext-2-raw-v1.zip
    python3 -I -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); open(sys.argv[2],"wb").write(z.read("wikitext-2-raw/wiki.test.raw"))' \
        /tmp/wikitext-2-raw-v1.zip bench/data/wiki.test.raw
fi

DEV=(--device /dev/dri); [[ "$BACKEND" == rocm* ]] && DEV+=(--device /dev/kfd)
{
echo "# $BACKEND $(docker run --rm "$LOCAL_IMAGE" cat /opt/strix/versions.txt | paste -sd' ')"
echo "## perplexity (wikitext-2, $CHUNKS x 2048, KV $KV_DTYPE)"
docker run --rm "${DEV[@]}" --group-add "$(getent group render | cut -d: -f3)" --ipc=host \
    --security-opt seccomp=unconfined -v "$MODEL_DIR:/models:ro" -v "$PWD/bench/data:/data:ro" \
    $(compgen -e | grep -E '^(GGML_|HIP_|AMD_|HSA_|RADV_)' | sed 's/^/-e /') \
    "$LOCAL_IMAGE" llama-perplexity -m "/models/$MODEL_FILE" -f /data/wiki.test.raw \
    -ngl 999 -fa on -ctk "$KV_DTYPE" -ctv "$KV_DTYPE" -lm "$LOAD_MODE" -lzm "$LAZY_MODE" \
    -c 2048 -b 2048 --chunks "$CHUNKS" 2>&1 | grep -E 'Final estimate|^\[' | tail -2

echo "## greedy consistency ($PARALLEL concurrent vs alone, MTP=$MTP)"
./start.sh restart >/dev/null || { echo "  FAIL: server did not start"; exit 1; }
rc=0; python3 -I bench/consistency.py "http://$HOST:$PORT/v1" "$PARALLEL" || rc=$?
./stop.sh >/dev/null
exit $rc
} | tee "$OUT"
