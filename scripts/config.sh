# Settings for start.sh. Every value can be overridden from the environment
# (PARALLEL=4 ./start.sh) or from a .env file next to start.sh (KEY=value lines);
# the environment wins over .env, and .env wins over these defaults.
# shellcheck shell=bash

# .env: KEY=value lines, data only, never sourced; the environment wins.
_env="$(dirname "${BASH_SOURCE[0]}")/../.env"
if [[ -f "$_env" ]]; then
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || { echo "Error: bad .env line: $line" >&2; exit 1; }
        [[ -z "${!BASH_REMATCH[1]+x}" ]] && export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
    done < "$_env"
fi

# ── Engine ───────────────────────────────────────────────────────────────────
: "${BACKEND:=rocm10.1-pm4}"          # rocm10.1-pm4 | rocm10.1-pm4-vk | rocm10.1 | rocm10.0-pm4 | vulkan
: "${IMAGE_REPO:=ghcr.io/halo-box/qwen3.8-flash-next-strix-halo-llama}"
: "${IMAGE:=$IMAGE_REPO:$BACKEND}"
: "${LOCAL_IMAGE:=qfn-strix:$BACKEND}" # built by scripts/prepare.sh when the pull fails
: "${CONTAINER_NAME:=qwen38-flash-next-strix}"
: "${LLAMA_PRS:=151:3cb54eb4811f11faa41b787bb273a4273c9e7e36}"  # open PRs merged at build time (number:sha)

# ── Model ────────────────────────────────────────────────────────────────────
: "${MODEL_DIR:=$HOME/models/qwen38-flash-next}"
: "${MODEL_FILE:=Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-v2.gguf}"
: "${MTP_FILE:=Qwen3.8-Flash-Next-MTP-ROCmFP4-FAST.gguf}"
: "${MMPROJ_FILE:=}"                   # e.g. mmproj-Qwen3.8-Flash-Next-f16.gguf to enable images
: "${SERVED_NAME:=Qwen3.8-Flash-Next}"

# ── Serving ──────────────────────────────────────────────────────────────────
: "${HOST:=127.0.0.1}"                 # 0.0.0.0 publishes on the LAN; set API_KEY then
: "${PORT:=8080}"
: "${API_KEY:=}"
: "${PARALLEL:=8}"                     # requests decoded together (slots)
: "${CONTEXT:=262144}"                 # total KV pool in tokens
: "${CONTEXT_PER_SLOT:=262144}"        # cap per slot (--kv-unified-per-slot); the model's native window
: "${KV_UNIFIED:=1}"                   # 1: one pool any slot can fill; 0: CONTEXT/PARALLEL per slot
: "${KV_DTYPE:=q8_0}"                  # f16 | q8_0 | q4_0
: "${BATCH:=4096}"
: "${UBATCH:=4096}"                 # 4096: full prefill speed; 8192+ does not fit beside a 262k context
: "${LAZY_MODE:=on-direct}"            # n-gram (PLE) table: on-direct | on | off
: "${LOAD_MODE:=none}"                 # none | dio | mmap. Not mmap: on Vulkan it intermittently wedges amdgpu, on ROCm KFD refuses it

# ── Speculative decoding ─────────────────────────────────────────────────────
: "${MTP:=1}"                          # 0 serves without the draft head
: "${SPEC_TYPE:=draft-mtp}"            # e.g. draft-mtp,ngram-mod
: "${MTP_DRAFT_N:=3}"
: "${MTP_ADAPTIVE:=0}"
: "${SPEC_N_RS_SEQ:=-1}"               # recurrent rollback snapshots per slot (#147); -1 follows MTP_DRAFT_N, 0 disables the fast path

# ── Sampling defaults (Qwen's thinking-mode values; a request's own values win) ─
: "${TEMPERATURE:=1.0}"
: "${TOP_P:=0.95}"
: "${TOP_K:=20}"

# ── Misc ─────────────────────────────────────────────────────────────────────
: "${EXTRA_ARGS:=}"                    # appended to llama-server; they win over the above
: "${READY_TIMEOUT:=1200}"             # seconds start.sh waits for /health
: "${GTT_MARGIN_GIB:=1}"               # start.sh stops the server if GTT gets this close to its limit while loading
: "${EVICT_PAGE_CACHE:=1}"             # drop the model files from the page cache before loading (see README: Troubleshooting)
