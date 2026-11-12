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
: "${BACKEND:=vulkan}"                # vulkan | rocm
case "$BACKEND" in
    rocm)   : "${IMAGE:=ghcr.io/halo-box/strix-llama.cpp:server-rocm-b12389@sha256:8ec68227753e1a501c3125b05a8fd686cda6cfbdce0d50f59b26f2060f25d98e}" ;;
    vulkan) : "${IMAGE:=ghcr.io/halo-box/strix-llama.cpp:server-vulkan-b12389@sha256:2c8a13709cfe9eb5dbcaf2a0de89ca2b4b047279c893c980215501397c3d142a}" ;;
    *) echo "Error: BACKEND must be rocm or vulkan, got '$BACKEND'" >&2; exit 1 ;;
esac
: "${SERVER_BIN:=}"                     # llama-server in an image whose entrypoint is not it; empty: the image's entrypoint
: "${CONTAINER_NAME:=qwen38-flash-next-strix}"

# ── Model ────────────────────────────────────────────────────────────────────
: "${MODEL_DIR:=$HOME/models/qwen38-flash-next}"
: "${MODEL_FILE:=Signal-3.8-Flash-Next-AP-Q4_K_XL.gguf}"
: "${MTP_FILE:=Qwen3.8-Flash-Next-MTP-Q8_0.gguf}"
: "${VISION:=1}"                        # image input (the model's own vision tower, 0.9 GB)
: "${MMPROJ_FILE:=mmproj-Qwen3.8-Flash-Next-f16.gguf}"
: "${SERVED_NAME:=Qwen3.8-Flash-Next}"

# ── Serving ──────────────────────────────────────────────────────────────────
: "${HOST:=127.0.0.1}"                 # 0.0.0.0 publishes on the LAN; set API_KEY then
: "${PORT:=8080}"
: "${API_KEY:=}"
: "${PARALLEL:=$([[ $BACKEND == vulkan ]] && echo 4 || echo 2)}"  # requests served at once, each with its own CONTEXT_PER_SLOT window; auto = as many as fit
: "${CONTEXT_PER_SLOT:=262144}"        # tokens each request may use (prompt + reply); the model's native window
: "${KV_UNIFIED:=0}"                   # 1: one shared pool of PARALLEL x CONTEXT_PER_SLOT instead of a window per slot
: "${KV_DTYPE:=$([[ $BACKEND == vulkan ]] && echo q8_0 || echo f16)}"  # q8_0 takes the maskless QSA path on Vulkan only (#271); on ROCm it grows compute per stream
: "${UBATCH:=2048}"                   # prompt batch; 4096 prefills ~8% faster on ROCm but fits fewer slots
: "${BATCH:=$UBATCH}"
: "${LAZY_MODE:=on-direct}"            # n-gram (PLE) table: on-direct | on | off
: "${CTX_CHECKPOINTS:=4}"              # recurrent-state checkpoints per slot (~112 MB each, host RAM; default 32)
: "${CACHE_RAM:=0}"                    # host prompt cache in MiB (0 = off; default 8192)
: "${LOAD_MODE:=none}"                 # none | dio | mmap. Not mmap: on Vulkan it intermittently wedges amdgpu, on ROCm KFD refuses it

# ── Speculative decoding ─────────────────────────────────────────────────────
: "${MTP:=1}"                          # 0 serves without the draft head
: "${SPEC_TYPE:=draft-mtp}"            # e.g. draft-mtp,ngram-mod
: "${MTP_DRAFT_N:=3}"                  # Signal, ROCm, 2 runs each: 3 drafts 36.1 prose / 53.9 code tok/s, 4 drafts 29.9 / 55.4
: "${MTP_ADAPTIVE:=0}"
: "${DRAFT_P_MIN:=0}"                 # stop a draft chain below this draft probability
: "${SPEC_N_RS_SEQ:=-1}"               # recurrent rollback snapshots per slot (#147); -1 follows MTP_DRAFT_N, 0 disables the fast path

# ── Sampling defaults (Qwen's thinking-mode values; a request's own values win) ─
: "${TEMPERATURE:=0.6}"
: "${TOP_P:=0.95}"
: "${TOP_K:=20}"
: "${MIN_P:=0.05}"

# ── Misc ─────────────────────────────────────────────────────────────────────
: "${EXTRA_ARGS:=}"                    # appended to llama-server; they win over the above
: "${READY_TIMEOUT:=1200}"             # seconds start.sh waits for /health
# GPU memory, measured with bench/memory.sh (Signal AP-Q4_K_XL, ubatch 2048, MTP and vision on, n-gram table on disk):
: "${MODEL_GIB:=70.1}"                 # the model, its draft head and vision tower
: "${COMPUTE_GIB:=$([[ $KV_DTYPE == q8_0 ]] && echo 8.5 || echo 6.5)}"      # compute buffers; they barely grow with PARALLEL
: "${KV_GIB_PER_262K:=$([[ $KV_DTYPE == q8_0 ]] && echo 4.3 || echo 7.9)}"  # KV and recurrent state of one 262,144-token window
: "${RAM_RESERVE_GIB:=10}"             # RAM kept for the OS (GTT is carved out of RAM); Mia's DGX Spark recipe keeps 9 GiB
: "${GTT_MARGIN_GIB:=2}"               # the memory plan stays this far under the GTT limit
