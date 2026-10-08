# Settings for start.sh. Every value can be overridden from the environment
# (PARALLEL=4 ./start.sh) or from a .env file next to start.sh (KEY=value lines);
# the environment wins over .env, and .env wins over these defaults.
# shellcheck shell=bash

# ── Engine ───────────────────────────────────────────────────────────────────
: "${BACKEND:=vulkan}"                 # vulkan | rocm10.1 | rocm10.1-pm4 | rocm10.0-pm4
: "${IMAGE_REPO:=ghcr.io/dzannotti/qwen3.8-flash-next-strix-halo-llama}"
: "${IMAGE:=$IMAGE_REPO:$BACKEND}"
: "${LOCAL_IMAGE:=qfn-strix:$BACKEND}" # built by scripts/prepare.sh when the pull fails
: "${CONTAINER_NAME:=qwen38-flash-next-strix}"

# ── Model ────────────────────────────────────────────────────────────────────
: "${MODEL_DIR:=/srv/models/gguf/qwen4exp}"
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
: "${BATCH:=2048}"
: "${UBATCH:=2048}"
: "${LAZY_MODE:=on-direct}"            # n-gram (PLE) table: on-direct | on | off
: "${LOAD_MODE:=mmap}"                 # --lazy-mode needs mmap

# ── Speculative decoding ─────────────────────────────────────────────────────
: "${MTP:=1}"                          # 0 serves without the draft head
: "${SPEC_TYPE:=draft-mtp}"            # e.g. draft-mtp,ngram-mod
: "${MTP_DRAFT_N:=3}"
: "${MTP_ADAPTIVE:=0}"

# ── Sampling defaults (Qwen's thinking-mode values; a request's own values win) ─
: "${TEMPERATURE:=1.0}"
: "${TOP_P:=0.95}"
: "${TOP_K:=20}"

# ── Misc ─────────────────────────────────────────────────────────────────────
: "${EXTRA_ARGS:=}"                    # appended to llama-server; they win over the above
: "${READY_TIMEOUT:=1200}"             # seconds start.sh waits for /health
: "${MIN_FREE_GIB:=8}"                 # start.sh stops the server if free RAM drops below this while loading
