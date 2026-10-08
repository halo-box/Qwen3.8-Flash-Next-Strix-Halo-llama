#!/usr/bin/env bash
# bench/run-all.sh [BACKEND...] — the whole measurement, one backend after another.
#
# Per backend: quality gate, then the KV-pool fit, then the server benchmark with MTP
# on and off. A backend that fails the quality gate gets no speed numbers. Waits for
# an idle machine before every step, and stops if a llama-server cannot be stopped
# (a wedged amdgpu driver needs a reboot; nothing after it would be trustworthy).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
BACKENDS=("${@:-vulkan rocm10.1 rocm10.1-pm4 rocm10.0-pm4}")
read -ra BACKENDS <<<"${BACKENDS[*]}"
LOG=results/run-all.log
mkdir -p results
log() { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$LOG"; }

idle() {
    for _ in $(seq 120); do
        local dirty building
        dirty=$(awk '/^Dirty:/{print int($2/1024)}' /proc/meminfo)
        building=$(pgrep -c -f 'buildkit-runc|docker-buildx' || true)
        if ! pgrep -x llama-server >/dev/null && ((dirty < 256 && building == 0)); then return 0; fi
        sync; sleep 5
    done
    pgrep -x llama-server >/dev/null && { log "ABORT: a llama-server will not exit (driver wedged?); reboot"; exit 1; }
}

step() { idle; log "$*"; "$@" >> "$LOG" 2>&1; local rc=$?; log "  -> exit $rc"; return $rc; }

for b in "${BACKENDS[@]}"; do
    export BACKEND=$b
    if ! step bench/quality.sh "$b"; then log "$b failed the quality gate; no speed runs"; continue; fi
    PARALLEL=8 step bench/fit.sh "$b"
    MTP=1 step bench/serve.sh "$b" mtp
    MTP=0 step bench/serve.sh "$b" nomtp
done
log "done"
