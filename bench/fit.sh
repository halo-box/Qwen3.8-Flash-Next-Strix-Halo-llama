#!/usr/bin/env bash
# bench/fit.sh BACKEND — the largest KV pool that loads, and what each step costs in GTT.
#
# Grows CONTEXT from START in STEP increments with the current PARALLEL and
# per-slot cap, and stops at the first size that fails. start.sh's GTT guard
# stops a load that nears the ttm limit, so no step can push past it.
# Writes results/fit/<BACKEND>.tsv.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
BACKEND=${1:?usage: bench/fit.sh BACKEND}
export BACKEND LOCAL_IMAGE="qfn-strix:$BACKEND"
. scripts/config.sh
: "${START:=262144}" "${STEP:=262144}" "${MAX:=2097152}"
mkdir -p results/fit
OUT=results/fit/$BACKEND.tsv
[[ -f "$OUT" ]] || printf 'parallel\tcontext\tper_slot\tmtp\tubatch\tresult\tload_s\tgtt_gib\n' > "$OUT"
GTT_USED=$(ls /sys/class/drm/card*/device/mem_info_gtt_used | head -n1)

for ((ctx = START; ctx <= MAX; ctx += STEP)); do
    t0=$SECONDS
    if CONTEXT=$ctx ./start.sh restart > "results/fit/$BACKEND-$ctx.log" 2>&1; then res=ok; else res=FAIL; fi
    gtt=$(grep -oE '[0-9.]+ of [0-9]+ GiB GTT' "results/fit/$BACKEND-$ctx.log" | cut -d' ' -f1)
    [[ -n "$gtt" ]] || gtt=$(grep -oE 'GTT reached [0-9]+' "results/fit/$BACKEND-$ctx.log" | grep -oE '[0-9]+$')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$PARALLEL" "$ctx" "$CONTEXT_PER_SLOT" "$MTP" "$UBATCH" \
        "$res" "$((SECONDS - t0))" "${gtt:-?}" | tee -a "$OUT"
    ./stop.sh >/dev/null 2>&1
    sleep 5
    [[ "$res" == ok ]] || break
done
