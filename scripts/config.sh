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
: "${BACKEND:=rocm}"                  # rocm (ROCm 10.1 + retained PM4) | vulkan (Mesa RADV)
: "${IMAGE_REPO:=ghcr.io/halo-box/qwen3.8-flash-next-strix-halo-llama}"
: "${CONTAINER_NAME:=qwen38-flash-next-strix}"
: "${LLAMA_PRS:=151:3cb54eb4811f11faa41b787bb273a4273c9e7e36}"  # open PRs merged at build time (number:sha)
# The image tag is a hash of everything that goes into the image (its Dockerfile, which pins the
# engine and runtime commits, the patches and LLAMA_PRS): changing any of them means a new image.
_root="$(dirname "${BASH_SOURCE[0]}")/.."
_hash=$(cat "$_root/docker/Dockerfile.$BACKEND" "$_root"/docker/patches/* 2>/dev/null | { cat; echo "$LLAMA_PRS"; } | sha256sum | cut -c1-12)
: "${IMAGE:=$IMAGE_REPO:$BACKEND-$_hash}"
LOCAL_IMAGE=$IMAGE

# ── Model ────────────────────────────────────────────────────────────────────
: "${MODEL_DIR:=$HOME/models/qwen38-flash-next}"
: "${MODEL_FILE:=Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-v2.gguf}"
: "${MTP_FILE:=Qwen3.8-Flash-Next-MTP-ROCmFP4-FAST.gguf}"
: "${VISION:=1}"                        # image input (the model's own vision tower, 0.9 GB)
: "${MMPROJ_FILE:=mmproj-Qwen3.8-Flash-Next-f16.gguf}"
: "${SERVED_NAME:=Qwen3.8-Flash-Next}"

# ── Serving ──────────────────────────────────────────────────────────────────
: "${HOST:=127.0.0.1}"                 # 0.0.0.0 publishes on the LAN; set API_KEY then
: "${PORT:=8080}"
: "${API_KEY:=}"
: "${PARALLEL:=auto}"                 # requests served at once, each with its own CONTEXT_PER_SLOT window; auto = as many as fit
: "${CONTEXT_PER_SLOT:=262144}"        # tokens each request may use (prompt + reply); the model's native window
: "${KV_UNIFIED:=0}"                   # 1: one shared pool of PARALLEL x CONTEXT_PER_SLOT instead of a window per slot
: "${KV_DTYPE:=q8_0}"                  # f16 | q8_0 | q4_0
: "${UBATCH:=2048}"                   # prompt batch; 4096 prefills ~8% faster on ROCm but fits fewer slots
: "${BATCH:=$UBATCH}"
: "${LAZY_MODE:=on-direct}"            # n-gram (PLE) table: on-direct | on | off
: "${CTX_CHECKPOINTS:=4}"              # recurrent-state checkpoints per slot (~112 MB each, host RAM; default 32)
: "${CACHE_RAM:=0}"                    # host prompt cache in MiB (0 = off; default 8192)
: "${LOAD_MODE:=none}"                 # none | dio | mmap. Not mmap: on Vulkan it intermittently wedges amdgpu, on ROCm KFD refuses it

# ── Speculative decoding ─────────────────────────────────────────────────────
: "${MTP:=1}"                          # 0 serves without the draft head
: "${SPEC_TYPE:=draft-mtp}"            # e.g. draft-mtp,ngram-mod
: "${MTP_DRAFT_N:=3}"
: "${MTP_ADAPTIVE:=0}"
: "${DRAFT_P_MIN:=0}"                 # stop a draft chain below this draft probability
: "${SPEC_N_RS_SEQ:=-1}"               # recurrent rollback snapshots per slot (#147); -1 follows MTP_DRAFT_N, 0 disables the fast path

# ── Sampling defaults (Qwen's thinking-mode values; a request's own values win) ─
: "${TEMPERATURE:=1.0}"
: "${TOP_P:=0.95}"
: "${TOP_K:=20}"

# ── Misc ─────────────────────────────────────────────────────────────────────
: "${EXTRA_ARGS:=}"                    # appended to llama-server; they win over the above
: "${READY_TIMEOUT:=1200}"             # seconds start.sh waits for /health
: "${RAM_RESERVE_GIB:=10}"             # RAM kept for the system when choosing PARALLEL=auto (GTT is carved out of RAM)
: "${GTT_MARGIN_GIB:=1}"               # start.sh stops the server if GTT gets this close to its limit while loading
