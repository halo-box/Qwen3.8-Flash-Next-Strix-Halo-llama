#!/usr/bin/env bash
# start.sh — serve Qwen3.8-Flash-Next with strix-llama.cpp in Docker.
#
#   ./start.sh              start (no-op if already running)
#   ./start.sh restart      stop the running server, then start
#   ./start.sh --print      print the docker command and exit
#   ./start.sh [restart] -- <llama-server args>   extra args, appended last
#   FOREGROUND=1 ./start.sh  stay attached to the server's log; exit with its exit code (systemd)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

RESTART=0 PRINT=0 EXTRA=()
while (($#)); do
    case "$1" in
        restart) RESTART=1 ;;
        --print) PRINT=1 ;;
        --) shift; EXTRA=("$@"); break ;;
        *) echo "usage: ./start.sh [restart] [--print] [-- llama-server args]" >&2; exit 1 ;;
    esac
    shift
done

# shellcheck source=scripts/config.sh
. scripts/config.sh
# shellcheck source=scripts/host.sh
. scripts/host.sh
[[ -n "$STRIX_RENDER" ]] || { echo "Error: no Strix Halo GPU (gfx1151) found; is the amdgpu driver loaded? Run ./setup.sh" >&2; exit 1; }

GTT_USED=$STRIX_SYSFS/mem_info_gtt_used
GTT_TOTAL=$STRIX_SYSFS/mem_info_gtt_total

# ── Memory plan ──────────────────────────────────────────────────────────────
# GTT the server takes (bench/memory.sh): the model with its draft head and vision tower,
# compute buffers that barely grow with the slots, and each slot's KV. GTT is carved out of
# RAM, and a GPU that fills GTT up to its limit has OOM-killed host services on this
# hardware, so the plan stays GTT_MARGIN_GIB under the limit and keeps RAM_RESERVE_GIB of RAM.
# RAM the kernel counts as CMA-free takes only movable pages, never GPU pages: some kernels
# report ~13 GiB of it on Strix Halo, and that lowers the ceiling for the GPU.
gtt_limit=$(awk '{print $1/2^30}' "$GTT_TOTAL")
ram=$(awk '/MemTotal/{print $2/2^20}' /proc/meminfo)
cma_free=$(awk '/CmaFree/{print $2/2^20}' /proc/meminfo)
budget=$(awk -v g="$gtt_limit" -v r="$ram" -v m="$GTT_MARGIN_GIB" -v k="$RAM_RESERVE_GIB" -v c="${cma_free:-0}" \
    'BEGIN{a=g-m; b=r-k; d=r-c-6; x=(a<b?a:b); printf "%.1f", (x<d?x:d)}')
estimate() { awk -v b="$MODEL_GIB" -v c="$COMPUTE_GIB" -v s="$KV_GIB_PER_262K" -v p="$1" -v w="$CONTEXT_PER_SLOT" 'BEGIN{printf "%.1f", b + c + s*p*w/262144}'; }
fits() { awk -v e="$(estimate "$1")" -v b="$budget" 'BEGIN{exit !(e <= b)}'; }
if [[ "$CONTEXT_PER_SLOT" == auto ]]; then
    [[ "$PARALLEL" != auto ]] || { echo "Error: set PARALLEL or CONTEXT_PER_SLOT; both cannot be auto" >&2; exit 1; }
    CONTEXT_PER_SLOT=$(awk -v g="$budget" -v b="$MODEL_GIB" -v c="$COMPUTE_GIB" -v s="$KV_GIB_PER_262K" -v p="$PARALLEL" \
        'BEGIN{w = int((g - b - c) / (s * p) * 16) * 16384; print (w > 262144 ? 262144 : w)}')
    ((CONTEXT_PER_SLOT >= 16384)) || { echo "Error: $PARALLEL request(s) do not fit in ${budget} GiB at any window: lower PARALLEL" >&2; exit 1; }
fi
if [[ "$PARALLEL" == auto ]]; then
    PARALLEL=0
    for p in 1 2 3 4 5 6 7 8; do fits $p && PARALLEL=$p; done
    ((PARALLEL > 0)) || { echo "Error: not even one slot fits in ${budget} GiB (GTT $(printf %.0f "$gtt_limit") GiB): see README, Requirements" >&2; exit 1; }
fi
EST_GIB=$(estimate "$PARALLEL")
if ! fits "$PARALLEL" && [[ "${FORCE:-0}" != 1 ]]; then
    best=0; for p in 1 2 3 4 5 6 7 8; do fits $p && best=$p; done
    echo "Error: $PARALLEL slots of $CONTEXT_PER_SLOT tokens need ~${EST_GIB} GiB of GTT; ${budget} GiB is available." >&2
    echo "       $best slot(s) fit (PARALLEL=$best), or shorten CONTEXT_PER_SLOT. FORCE=1 skips this check." >&2
    exit 1
fi
CONTEXT=$((PARALLEL * CONTEXT_PER_SLOT))

step() { printf '\n\033[1m[%s] %s\033[0m\n' "$1" "$2"; }
die() { echo "Error: $*" >&2; exit 1; }

# ── 1. Setup ─────────────────────────────────────────────────────────────────
if ((!PRINT)); then
    step 1/5 "Setup"
    scripts/prepare.sh
    echo "  image:  $IMAGE ($(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}} {{index .Config.Labels "org.opencontainers.image.revision"}}' "$IMAGE"))"
    echo "  model:  $MODEL_DIR/$MODEL_FILE"
fi

# ── 2. Arguments ─────────────────────────────────────────────────────────────
ARGS=(
    -m "/models/$MODEL_FILE" --alias "$SERVED_NAME"
    --host 0.0.0.0 --port 8080
    -ngl 999 -fa on --jinja --fit off
    -np "$PARALLEL" -c "$CONTEXT"
    -ctk "$KV_DTYPE" -ctv "$KV_DTYPE"
    -b "$BATCH" -ub "$UBATCH"
    --load-mode "$LOAD_MODE" --lazy-mode "$LAZY_MODE"
    --temp "$TEMPERATURE" --top-p "$TOP_P" --top-k "$TOP_K" --min-p "$MIN_P"
    --metrics
    --ctx-checkpoints "$CTX_CHECKPOINTS" --cache-ram "$CACHE_RAM"
)
if [[ "$KV_UNIFIED" == 1 ]]; then ARGS+=(--kv-unified); else ARGS+=(--no-kv-unified); fi
[[ -n "$API_KEY" ]] && ARGS+=(--api-key "$API_KEY")
[[ "$VISION" == 1 ]] && ARGS+=(--mmproj "/models/$MMPROJ_FILE")
if [[ "$MTP" == 1 ]]; then
    ARGS+=(--spec-type "$SPEC_TYPE" --spec-draft-model "/models/$MTP_FILE"
           --spec-draft-ngl 999 --spec-draft-n-max "$MTP_DRAFT_N" --no-spec-draft-backend-sampling
           -ctkd "$KV_DTYPE" -ctvd "$KV_DTYPE")
    [[ "$MTP_ADAPTIVE" == 1 ]] && ARGS+=(--spec-draft-adaptive)
    ARGS+=(--spec-n-rs-seq "$SPEC_N_RS_SEQ" --spec-draft-p-min "$DRAFT_P_MIN" --spec-draft-max-slots "$SPEC_DRAFT_MAX_SLOTS")
fi
# shellcheck disable=SC2206
[[ -n "$EXTRA_ARGS" ]] && ARGS+=($EXTRA_ARGS)
ARGS+=("${EXTRA[@]}")

DEVICES=(--device "$STRIX_RENDER")
ENTRY=(); [[ -n "$SERVER_BIN" ]] && ENTRY=(--entrypoint "$SERVER_BIN")
ENVS=()
if [[ "$BACKEND" == rocm ]]; then
    DEVICES+=(--device /dev/kfd)
    ARGS+=(-dev ROCm0)
    [[ "$MTP" == 1 ]] && ARGS+=(--spec-draft-device ROCm0)
    [[ -n "${HIP_LAUNCH_BLOCKING:-}" ]] && ENVS+=(-e "HIP_LAUNCH_BLOCKING=$HIP_LAUNCH_BLOCKING")
fi
for v in $(compgen -e | grep -E '^(GGML_|AMD_|HSA_|RADV_|DEBUG_HIP_|LLAMA_ARG_)' || true); do ENVS+=(-e "$v=${!v}"); done

GROUPS_ADD=()
for g in $(stat -c %g "$STRIX_RENDER" $([[ "$BACKEND" == rocm ]] && echo /dev/kfd) | sort -u); do GROUPS_ADD+=(--group-add "$g"); done

CMD=(docker run -d --name "$CONTAINER_NAME"
     "${DEVICES[@]}" "${GROUPS_ADD[@]}"
     --ipc=host --security-opt seccomp=unconfined
     -p "$HOST:$PORT:8080" -v "$MODEL_DIR:/models:ro" "${ENVS[@]}" "${ENTRY[@]}"
     "$IMAGE" "${ARGS[@]}")

if ((PRINT)); then printf '%q ' "${CMD[@]}"; echo; exit 0; fi

# ── 3. Launch ────────────────────────────────────────────────────────────────
step 3/5 "Launch"
# Check the arguments first, so a typo on restart leaves the running server alone.
docker run --rm "${DEVICES[@]}" "${ENTRY[@]}" "${GROUPS_ADD[@]}" \
    "$IMAGE" "${ARGS[@]}" --help >/dev/null 2>&1 \
    || die "llama-server rejected the arguments (run ./start.sh --print)"
if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    if ((RESTART)); then ./stop.sh; else
        if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" == true ]]; then
            echo "  already running; ./start.sh restart to restart it"; exit 0
        fi
        docker rm "$CONTAINER_NAME" >/dev/null
    fi
fi
# A previous server that has not fully exited still holds its GPU memory; loading a
# second one on top of it is how the amdgpu driver ends up wedged.
if pids=$(pgrep -x llama-server); then
    die "another llama-server is still running (pid $(echo $pids)); stop it first, or reboot if it cannot be killed"
fi
# Wait until a previous server's GTT is released, and flush pending writes: a load
# that races either has failed with a lost device.
for _ in $(seq 60); do (($(awk '{print int($1/1073741824)}' "$GTT_USED") < 2)) && break; sleep 1; done
(($(awk '{print int($1/1073741824)}' "$GTT_USED") < 2)) || die "GTT still in use by something else; is another GPU program running?"
sync
"${CMD[@]}" >/dev/null
echo "  $BACKEND, $PARALLEL slot(s) of $CONTEXT_PER_SLOT tokens, $KV_DTYPE KV, vision $([[ $VISION == 1 ]] && echo on || echo off); ~${EST_GIB} of $(printf %.0f "$gtt_limit") GiB GTT"

# ── 4. Loading ───────────────────────────────────────────────────────────────
step 4/5 "Loading"
t0=$SECONDS
docker logs -f "$CONTAINER_NAME" 2>&1 | grep --line-buffered -E ' E |error|failed' &
LOGPID=$!
trap 'kill $LOGPID 2>/dev/null || true' EXIT
next=10
until curl -sf "http://$HOST:$PORT/health" >/dev/null 2>&1; do
    [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" == true ]] \
        || { docker logs --tail 30 "$CONTAINER_NAME" >&2; die "the server stopped while loading"; }
    ((SECONDS - t0 < READY_TIMEOUT)) || die "not ready after ${READY_TIMEOUT}s"
    # Vulkan fills GTT pages as they are first touched, past any allocation-time check; near
    # the GTT limit the kernel runs out of RAM and OOM-kills host services. Kill at once.
    gtt=$(awk '{print int($1/1048576)}' "$GTT_USED")
    avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
    if ((gtt > ${budget%.*} * 1024 + 1024 || avail < 4096)); then
        docker kill "$CONTAINER_NAME" >/dev/null 2>&1 || true
        die "killed: GTT reached $((gtt / 1024)) GiB (budget ${budget}), MemAvailable $((avail / 1024)) GiB, while loading. Lower PARALLEL or CONTEXT_PER_SLOT."
    fi
    if ((SECONDS - t0 >= next)); then
        printf '  %4ds  %5.1f of ~%s GiB loaded (%d%%)\n' $((SECONDS - t0)) "$(awk '{print $1/2^30}' "$GTT_USED")" "$EST_GIB" \
            "$(awk -v e="$EST_GIB" '{printf "%d", 100*$1/2^30/e}' "$GTT_USED")"
        next=$((next + 10))
    fi
    sleep 0.5
done
kill $LOGPID 2>/dev/null || true
echo "  ready in $((SECONDS - t0))s, $(awk '{printf "%.1f",$1/2^30}' "$GTT_USED") of $(awk '{printf "%.0f",$1/2^30}' "$GTT_TOTAL") GiB GTT in use"

# ── 5. Smoke test ────────────────────────────────────────────────────────────
step 5/5 "Smoke test"
AUTH=(); [[ -n "$API_KEY" ]] && AUTH=(-H "Authorization: Bearer $API_KEY")
reply=$(curl -sf "${AUTH[@]}" "http://$HOST:$PORT/v1/chat/completions" -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"Reply with the single word: ready"}],"max_tokens":512,"chat_template_kwargs":{"enable_thinking":false}}' \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["choices"][0]["message"]["content"].strip())') \
    || die "smoke test failed; docker logs $CONTAINER_NAME"
echo "  model says: $reply"
printf '\n\033[1;32m%s is now LIVE on http://%s:%s/v1\033[0m\n' "$SERVED_NAME" "$HOST" "$PORT"
if [[ "${FOREGROUND:-0}" == 1 ]]; then
    trap - EXIT
    docker logs -f --since 0s "$CONTAINER_NAME" &
    exit "$(docker wait "$CONTAINER_NAME")"
fi
