#!/usr/bin/env bash
# bench/quality.sh BACKEND — correctness gate before any speed number counts.
#
# 1. Perplexity on wikitext-2 decoding one sequence at a time, then four sequences
#    batched together. They must agree within their statistical error: batched
#    inference is where the gfx1151 HIP async bug shows (strix-llama.cpp README:
#    perplexity ~88 against ~9.4).
# 2. For information, not the gate: the same prompt answered alone and by PARALLEL
#    concurrent requests through the recipe's server. llama.cpp is not
#    batch-invariant, so greedy text may drift apart; this reports how far it agrees.
# Writes results/quality/<BACKEND>.txt.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
BACKEND=${1:?usage: bench/quality.sh BACKEND}
export BACKEND LOCAL_IMAGE="qfn-strix:$BACKEND"
. scripts/config.sh
: "${CHUNKS:=40}" "${PPL_TIMEOUT:=1200}"
OUT=results/quality/$BACKEND.txt
[[ -f "$MODEL_DIR/$MODEL_FILE" ]] || { echo "Error: missing $MODEL_DIR/$MODEL_FILE" >&2; exit 2; }
mkdir -p results/quality bench/data

if [[ ! -f bench/data/wiki.test.raw ]]; then
    tmp=$(mktemp -d)
    curl -sL -o "$tmp/w.zip" https://huggingface.co/datasets/ggml-org/ci/resolve/main/wikitext-2-raw-v1.zip
    python3 -I -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); open(sys.argv[2],"wb").write(z.read("wikitext-2-raw/wiki.test.raw"))' \
        "$tmp/w.zip" bench/data/wiki.test.raw
    rm -rf "$tmp"
fi

DEV=(--device /dev/dri); [[ "$BACKEND" == rocm* ]] && DEV+=(--device /dev/kfd)
ppl() {  # ppl BATCH -> "PPL ERR"; a run that takes over PPL_TIMEOUT is stopped
    local name="qfn-ppl-$BACKEND-$1"
    timeout "$PPL_TIMEOUT" docker run --rm --name "$name" "${DEV[@]}" \
        --group-add "$(getent group render | cut -d: -f3)" --ipc=host \
        --security-opt seccomp=unconfined -v "$MODEL_DIR:/models:ro" -v "$PWD/bench/data:/data:ro" \
        $(compgen -e | grep -E '^(GGML_|HIP_|AMD_|HSA_|RADV_)' | sed 's/^/-e /') \
        "$LOCAL_IMAGE" llama-perplexity -m "/models/$MODEL_FILE" -f /data/wiki.test.raw \
        -ngl 999 -fa on -ctk "$KV_DTYPE" -ctv "$KV_DTYPE" -lm "$LOAD_MODE" -lzm "$LAZY_MODE" \
        -c 2048 -b "$1" --chunks "$CHUNKS" 2>&1 \
        | grep -oE 'Final estimate: PPL = [0-9.]+ \+/- [0-9.]+' | awk '{print $5, $7}' || true
    docker stop -t 10 "$name" >/dev/null 2>&1 || true
}

{
echo "# $BACKEND $(docker run --rm "$LOCAL_IMAGE" cat /opt/strix/versions.txt | paste -sd' ')"
t0=$SECONDS; read -r p1 e1 <<<"$(ppl 2048)"; t1=$((SECONDS - t0))
t0=$SECONDS; read -r p4 e4 <<<"$(ppl 8192)"; t4=$((SECONDS - t0))
echo "perplexity, 1 sequence:   ${p1:-FAILED} +/- ${e1:-?}  (${t1}s)"
echo "perplexity, 4 batched:    ${p4:-FAILED} +/- ${e4:-?}  (${t4}s)"
gate=FAIL
if [[ -n "${p1:-}" && -n "${p4:-}" ]]; then
    gate=$(python3 -I -c 'import sys
p1,e1,p4,e4=map(float,sys.argv[1:])
print("PASS" if abs(p1-p4) <= 2*max(e1,e4) else "FAIL")' "$p1" "$e1" "$p4" "$e4")
fi
echo "gate: $gate (batched must match single within 2 sigma)"

echo "greedy, $PARALLEL concurrent vs alone (MTP=$MTP), information only:"
if [[ "$gate" == PASS ]] && ./start.sh restart >/dev/null; then
    python3 -I bench/consistency.py "http://$HOST:$PORT/v1" "$PARALLEL" || true
    ./stop.sh >/dev/null
else
    echo "  skipped"
fi
[[ "$gate" == PASS ]]
} | tee "$OUT"
