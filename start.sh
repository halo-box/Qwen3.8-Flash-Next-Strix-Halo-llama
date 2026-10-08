#!/usr/bin/env bash
# start.sh — serve Qwen3.8-Flash-Next with strix-llama.cpp in Docker.
#
#   ./start.sh              start (no-op if already running)
#   ./start.sh restart      stop the running server, then start
#   ./start.sh --print      print the docker command and exit
#   ./start.sh [restart] -- <llama-server args>   extra args, appended last
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

# .env: KEY=value lines, data only, never sourced; the environment wins.
if [[ -f .env ]]; then
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || { echo "Error: bad .env line: $line" >&2; exit 1; }
        [[ -z "${!BASH_REMATCH[1]+x}" ]] && export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
    done < .env
fi
# shellcheck source=scripts/config.sh
. scripts/config.sh

step() { printf '\n\033[1m[%s] %s\033[0m\n' "$1" "$2"; }
die() { echo "Error: $*" >&2; exit 1; }

# ── 1. Setup ─────────────────────────────────────────────────────────────────
step 1/5 "Setup"
for f in "$MODEL_FILE" ${MTP_FILE:+"$MTP_FILE"} ${MMPROJ_FILE:+"$MMPROJ_FILE"}; do
    [[ -f "$MODEL_DIR/$f" ]] || die "missing $MODEL_DIR/$f (see README: Get the model)"
done
if ! docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1; then
    scripts/prepare.sh
fi
echo "  image:  $LOCAL_IMAGE ($(docker run --rm "$LOCAL_IMAGE" cat /opt/strix/versions.txt | paste -sd' '))"
echo "  model:  $MODEL_DIR/$MODEL_FILE"

# ── 2. Arguments ─────────────────────────────────────────────────────────────
ARGS=(
    -m "/models/$MODEL_FILE" --alias "$SERVED_NAME"
    --host 0.0.0.0 --port 8080
    -ngl 999 -fa on --jinja --fit off
    -np "$PARALLEL" -c "$CONTEXT" --kv-unified
    -ctk "$KV_DTYPE" -ctv "$KV_DTYPE"
    -b "$BATCH" -ub "$UBATCH"
    --load-mode "$LOAD_MODE" --lazy-mode "$LAZY_MODE"
    --temp "$TEMPERATURE" --top-p "$TOP_P" --top-k "$TOP_K"
    --metrics
)
[[ -n "$API_KEY" ]] && ARGS+=(--api-key "$API_KEY")
[[ -n "$MMPROJ_FILE" ]] && ARGS+=(--mmproj "/models/$MMPROJ_FILE")
if [[ "$MTP" == 1 ]]; then
    ARGS+=(--spec-type "$SPEC_TYPE" --spec-draft-model "/models/$MTP_FILE"
           --spec-draft-ngl 999 --spec-draft-n-max "$MTP_DRAFT_N"
           -ctkd "$KV_DTYPE" -ctvd "$KV_DTYPE")
    [[ "$MTP_ADAPTIVE" == 1 ]] && ARGS+=(--spec-draft-adaptive)
fi
# shellcheck disable=SC2206
[[ -n "$EXTRA_ARGS" ]] && ARGS+=($EXTRA_ARGS)
ARGS+=("${EXTRA[@]}")

DEVICES=(--device /dev/dri)
ENVS=()
if [[ "$BACKEND" == rocm* ]]; then
    DEVICES+=(--device /dev/kfd)
    [[ -n "${HIP_LAUNCH_BLOCKING:-}" ]] && ENVS+=(-e "HIP_LAUNCH_BLOCKING=$HIP_LAUNCH_BLOCKING")
fi
for v in $(compgen -e | grep -E '^(GGML_|AMD_|HSA_|RADV_|DEBUG_HIP_)' || true); do ENVS+=(-e "$v=${!v}"); done

CMD=(docker run -d --name "$CONTAINER_NAME"
     "${DEVICES[@]}" --group-add "$(getent group render | cut -d: -f3)"
     --group-add "$(getent group video | cut -d: -f3)"
     --ipc=host --security-opt seccomp=unconfined
     -p "$HOST:$PORT:8080" -v "$MODEL_DIR:/models:ro" "${ENVS[@]}"
     "$LOCAL_IMAGE" llama-server "${ARGS[@]}")

if ((PRINT)); then printf '%q ' "${CMD[@]}"; echo; exit 0; fi

# ── 3. Launch ────────────────────────────────────────────────────────────────
step 3/5 "Launch"
if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    if ((RESTART)); then ./stop.sh; else
        if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" == true ]]; then
            echo "  already running; ./start.sh restart to restart it"; exit 0
        fi
        docker rm "$CONTAINER_NAME" >/dev/null
    fi
fi
docker run --rm "${DEVICES[@]}" --group-add "$(getent group render | cut -d: -f3)" \
    "$LOCAL_IMAGE" llama-server "${ARGS[@]}" --help >/dev/null 2>&1 \
    || die "llama-server rejected the arguments (run ./start.sh --print)"
"${CMD[@]}" >/dev/null
echo "  container $CONTAINER_NAME, backend $BACKEND, $PARALLEL slots, $CONTEXT-token KV pool ($KV_DTYPE)"

# ── 4. Loading ───────────────────────────────────────────────────────────────
step 4/5 "Loading"
t0=$SECONDS
docker logs -f "$CONTAINER_NAME" 2>&1 | grep --line-buffered -E 'load_tensors|model buffer|KV buffer|compute buffer|error|failed|listening' &
LOGPID=$!
trap 'kill $LOGPID 2>/dev/null || true' EXIT
until curl -sf "http://$HOST:$PORT/health" >/dev/null 2>&1; do
    [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" == true ]] \
        || { docker logs --tail 30 "$CONTAINER_NAME" >&2; die "the server stopped while loading"; }
    ((SECONDS - t0 < READY_TIMEOUT)) || die "not ready after ${READY_TIMEOUT}s"
    sleep 2
done
kill $LOGPID 2>/dev/null || true
echo "  ready in $((SECONDS - t0))s"

# ── 5. Smoke test ────────────────────────────────────────────────────────────
step 5/5 "Smoke test"
AUTH=(); [[ -n "$API_KEY" ]] && AUTH=(-H "Authorization: Bearer $API_KEY")
reply=$(curl -sf "${AUTH[@]}" "http://$HOST:$PORT/v1/chat/completions" -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"Reply with the single word: ready"}],"max_tokens":512,"chat_template_kwargs":{"enable_thinking":false}}' \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["choices"][0]["message"]["content"].strip())') \
    || die "smoke test failed; docker logs $CONTAINER_NAME"
echo "  model says: $reply"
printf '\n\033[1;32m%s is now LIVE on http://%s:%s/v1\033[0m\n' "$SERVED_NAME" "$HOST" "$PORT"
