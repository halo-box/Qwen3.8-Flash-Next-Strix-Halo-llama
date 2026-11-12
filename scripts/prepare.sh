#!/usr/bin/env bash
# prepare.sh — one-time setup, safe to re-run: the model files, then the engine image.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/config.sh

# ── Model files (resumable; verified once against Hugging Face's sha256) ─────
fetch() {  # fetch FILE URL SIZE SHA256 DEFAULT_NAME; only the default files are downloaded
    local f="$MODEL_DIR/$1" url=$2 size=$3 sha=$4
    if [[ "$1" != "$5" ]]; then
        [[ -f "$f" ]] || { echo "Error: $f not found" >&2; exit 1; }
        return 0
    fi
    if [[ ! -f "$f" || $(stat -c %s "$f") -ne $size ]]; then
        local have=0; [[ -f "$f" ]] && have=$(stat -c %s "$f")
        local free; free=$(df -B1 --output=avail "$MODEL_DIR" | tail -1)
        ((free > size - have + 2**30)) || { echo "Error: not enough disk in $MODEL_DIR for $1" >&2; exit 1; }
        echo "downloading $1 ($((size / 2**30)) GiB, resumes if interrupted)"
        curl -fL --progress-bar --retry 10 --retry-delay 5 -C - -o "$f" "$url"
    fi
    if [[ ! -f "$f.verified" ]]; then
        echo "verifying $1"
        [[ "$(sha256sum "$f" | cut -d' ' -f1)" == "$sha" ]] \
            || { echo "Error: $1 does not match its published sha256; delete it and re-run" >&2; exit 1; }
        touch "$f.verified"
    fi
}
mkdir -p "$MODEL_DIR"
fetch "$MODEL_FILE" \
    https://huggingface.co/agentionai/Signal-3.8-Flash-Next-GGUF/resolve/main/AP-Q4_K_XL/Signal-3.8-Flash-Next-AP-Q4_K_XL.gguf \
    101142769984 427a7a10dd5a98d77c71be62a89d14e7408fc61a84c6efe889393852282cd3c6 \
    Signal-3.8-Flash-Next-AP-Q4_K_XL.gguf
fetch "$MTP_FILE" \
    https://huggingface.co/agentionai/Qwen3.8-Flash-Next-MTP-Q8_0-GGUF/resolve/main/Qwen3.8-Flash-Next-MTP-Q8_0.gguf \
    4135893408 554f3d1230cc1a8e2d63e3322f113218f3e052156d98328e9f21fb97db48af7f \
    Qwen3.8-Flash-Next-MTP-Q8_0.gguf

if [[ "$VISION" == 1 ]]; then
    fetch "$MMPROJ_FILE" \
        https://huggingface.co/agentionai/Signal-3.8-Flash-Next-GGUF/resolve/main/mmproj-F16.gguf \
        904004128 f456cd796fdbdef0cadb22710b54e0071b6cdf22c07963365baa898267aec517 \
        mmproj-Qwen3.8-Flash-Next-f16.gguf
fi

# ── Engine image: strix-llama.cpp's own, pinned in scripts/config.sh ─────────
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull "$IMAGE" \
    || { echo "Error: could not pull $IMAGE" >&2; exit 1; }
