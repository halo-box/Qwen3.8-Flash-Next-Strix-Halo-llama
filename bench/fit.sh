#!/usr/bin/env bash
# bench/fit.sh BACKEND — which KV pools load, and what they cost in GTT.
# Each case: "PARALLEL CONTEXT KV_UNIFIED". Writes results/fit/<BACKEND>.tsv.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
BACKEND=${1:?usage: bench/fit.sh BACKEND}
export BACKEND LOCAL_IMAGE="qfn-strix:$BACKEND"
CASES=${CASES:-"8 2097152 0|8 1048576 1|4 1048576 0|8 524288 1|8 262144 1"}
mkdir -p results/fit
OUT=results/fit/$BACKEND.tsv
printf 'parallel\tcontext\tkv_unified\tper_slot\tresult\tload_s\tgtt_gib\tmem_avail_gib\twarnings\n' > "$OUT"
IFS='|' read -ra cs <<<"$CASES"
for c in "${cs[@]}"; do
    read -r p ctx u <<<"$c"
    t0=$SECONDS
    if PARALLEL=$p CONTEXT=$ctx KV_UNIFIED=$u timeout 1200 ./start.sh restart >/tmp/fit.log 2>&1; then res=ok; else res=FAIL; fi
    gtt=$(awk '{printf "%.1f",$1/2^30}' /sys/class/drm/card0/device/mem_info_gtt_used)
    avail=$(awk '/MemAvailable/{printf "%.1f",$2/2^20}' /proc/meminfo)
    warn=$(docker logs qwen38-flash-next-strix 2>&1 | grep -oE 'Failed to allocate[^(]*|DeviceLost[A-Za-z]*|out of memory|n_ctx_seq \([0-9]+\) > n_ctx_train' | sort -u | paste -sd';')
    slot=$(( u == 1 ? ctx : ctx / p ))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$ctx" "$u" "$slot" "$res" "$((SECONDS-t0))" "$gtt" "$avail" "$warn" | tee -a "$OUT"
    ./stop.sh >/dev/null 2>&1
    sleep 5
done
