#!/usr/bin/env bash
# bench/sweep.sh PLAN — run bench/sparkdash.py against a list of server configurations.
#
# PLAN is a file with one configuration a line, three fields separated by "|": a label,
# KEY=value settings for start.sh, and arguments for bench/sparkdash.py. Blank lines and
# # comments are skipped.
#
#   vulkan       | BACKEND=vulkan                       |
#   vulkan-ub512 | BACKEND=vulkan UBATCH=512 BATCH=512  | --clients ""
#   rocm-c4      | BACKEND=rocm PARALLEL=4              | --clients 1,2,3,4 --prefill ""
#
# Each run waits for an idle machine (no build, no leftover llama-server, writes flushed)
# and writes results/sparkdash/<label>.md and .json. A server that will
# not exit stops the sweep: a wedged amdgpu driver needs a reboot.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PLAN=${1:?usage: bench/sweep.sh PLAN}
mkdir -p results/sparkdash
LOG=results/sparkdash/sweep.log
log() { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$LOG"; }

idle() {
    # A load started right after an image build has failed with a lost device, so after
    # any build it also waits COOLDOWN seconds for the export's I/O to settle.
    local saw_build=0
    for _ in $(seq 120); do
        local dirty building
        dirty=$(awk '/^Dirty:/{print int($2/1024)}' /proc/meminfo)
        building=$(pgrep -c -f '[b]uildkit-runc|[d]ocker-buildx' || true)
        ((building > 0)) && saw_build=1
        if ! pgrep -x llama-server >/dev/null && ((dirty < 256 && building == 0)); then
            # also when the build finished just before this sweep started
            local newest age
            newest=$(docker image ls --format '{{.CreatedAt}}' | head -n1 | awk '{print $1" "$2" "$3}')
            age=$(( $(date +%s) - $(date -d "$newest" +%s 2>/dev/null || echo 0) ))
            if ((saw_build || age < ${COOLDOWN:-60})); then sync; sleep "${COOLDOWN:-60}"; fi
            return 0
        fi
        sync; sleep 5
    done
    log "ABORT: machine not idle (a llama-server will not exit?)"; exit 1
}

while IFS='|' read -r label settings speed_args; do
    label=$(echo $label)
    [[ -z "$label" || "$label" == \#* ]] && continue
    idle
    log "$label: $settings | $speed_args"
    # shellcheck disable=SC2086
    if ! env $settings ./start.sh restart >> "$LOG" 2>&1 < /dev/null; then
        log "$label: server did not start"; ./stop.sh >/dev/null 2>&1; continue
    fi
    log "$label: image $(docker inspect -f '{{.Config.Image}} {{index .Config.Labels "org.opencontainers.image.revision"}}' qwen38-flash-next-strix)"
    eval "args=($speed_args)"
    python3 -I bench/sparkdash.py --label "$label" "${args[@]}" >> "$LOG" 2>&1 < /dev/null \
        || log "$label: sparkdash.py failed"
    ./stop.sh >/dev/null 2>&1
    log "$label: done"
done < "$PLAN"
docker rm -f sparkdash-bench-recipe >/dev/null 2>&1
log "sweep finished"
