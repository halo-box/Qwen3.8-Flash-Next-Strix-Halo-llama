#!/usr/bin/env bash
# bench/memory.sh PLAN — what each server configuration takes on the GPU.
#
# PLAN has one configuration a line, "label | KEY=value settings for start.sh", smallest first.
# Each one is started (FORCE=1: the memory plan is what is being measured; start.sh still kills
# a load that passes its budget), its device buffers are read from the server log, and it is
# stopped. The first configuration that does not load ends the run. Writes
# results/memory/<plan name>.md:
#
#   | label | model | KV + RS | compute | GTT in use | result |
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PLAN=${1:?usage: bench/memory.sh PLAN}
. scripts/config.sh
mkdir -p results/memory
OUT=results/memory/$(basename "$PLAN" .txt).md
echo "| Configuration | Model | KV + RS | Compute | GTT in use | Result |" > "$OUT"
echo "| --- | ---: | ---: | ---: | ---: | --- |" >> "$OUT"

gib() { awk -v m="$1" 'BEGIN{printf "%.1f GiB", m / 1024}'; }
sum() {  # sum KIND LOG: MiB of the device buffers (not host, not CPU) of that kind
    grep -E "^[^ ]* +[A-Za-z]+[0-9]+ +$1 buffer size = " "$2" \
        | grep -Ev '_Host|CPU' | awk -F'= ' '{s += $2} END {printf "%.0f", s}'
}

while IFS='|' read -r label settings; do
    label=$(echo $label)
    [[ -z "$label" || "$label" == \#* ]] && continue
    log=$(mktemp)
    # shellcheck disable=SC2086
    if env FORCE=1 $settings ./start.sh restart -- -lv 4 > "$log.start" 2>&1 < /dev/null; then
        gtt=$(grep -o 'ready in [0-9]*s, [0-9.]* of' "$log.start" | awk '{print $4 " GiB"}')
        result=ok
    else
        gtt="-"
        result=$(grep -oE 'allocating [0-9.]+ MiB on device [0-9]+: [a-zA-Z]+ failed[^,]*|GTT reached [0-9]+ of [0-9]+ GiB|failed to allocate [a-z ]+ buffers' "$log.start" | head -1)
        result=${result:-failed, see $log.start}
    fi
    docker logs "$CONTAINER_NAME" > "$log" 2>&1 || true
    sed -E 's/^[0-9.]+ [A-Z] //' "$log" > "$log.clean"
    model=$(sum model "$log.clean"); kv=$(( $(sum KV "$log.clean") + $(sum RS "$log.clean") )); compute=$(sum compute "$log.clean")
    echo "| $label | $(gib "$model") | $(gib "$kv") | $(gib "$compute") | $gtt | $result |" | tee -a "$OUT"
    ./stop.sh > /dev/null 2>&1
    rm -f "$log" "$log.clean" "$log.start"
    [[ "$result" == ok ]] || break
    sleep 5
done < "$PLAN"
