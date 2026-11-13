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
        local free; free=$(df -Pk "$MODEL_DIR" | awk 'NR == 2 {print $4 * 1024}')
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
UD=Qwen3.8-Flash-Next-UD-Q4_K_XL
fetch "$MODEL_FILE" https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/UD-Q4_K_XL/$UD-00001-of-00004.gguf \
    10946618 acc44040f74d0e55fb89c3967056cce5dbda1bcc52e909c3ba6fc72b5e9c0858 $UD-00001-of-00004.gguf
if [[ "$MODEL_FILE" == $UD-00001-of-00004.gguf ]]; then
    fetch $UD-00002-of-00004.gguf https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/UD-Q4_K_XL/$UD-00002-of-00004.gguf \
        49720539552 45792ae869072d8229384c51c7c73dd959e191505252b41dd71852d9746f5ce4 $UD-00002-of-00004.gguf
    fetch $UD-00003-of-00004.gguf https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/UD-Q4_K_XL/$UD-00003-of-00004.gguf \
        32803030176 8c76e79d444b16a663d9c8db54e585ed3b1da13eebd2619c37b0c355da803c82 $UD-00003-of-00004.gguf
    fetch $UD-00004-of-00004.gguf https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/UD-Q4_K_XL/$UD-00004-of-00004.gguf \
        28800138432 5de8b5dbf89409acc39468decafd4a4a95b13c29d88a14b0356107897829ec36 $UD-00004-of-00004.gguf
fi
fetch "$MTP_FILE" https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/MTP/mtp-Qwen3.8-Flash-Next-Q8_0.gguf \
    4137429120 58a47d6a216307e9b97172d5bfdc3436a8994b632f5e436b9bb6edf8951da8d1 mtp-Qwen3.8-Flash-Next-Q8_0.gguf

if [[ "$VISION" == 1 ]]; then
    fetch "$MMPROJ_FILE" \
        https://huggingface.co/agentionai/Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-GGUF/resolve/main/mmproj/mmproj-Qwen3.8-Flash-Next-f16.gguf \
        904004128 f456cd796fdbdef0cadb22710b54e0071b6cdf22c07963365baa898267aec517 \
        mmproj-Qwen3.8-Flash-Next-f16.gguf
fi

# ── Engine image: strix-llama.cpp's own, pinned in scripts/config.sh ─────────
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull "$IMAGE" \
    || { echo "Error: could not pull $IMAGE" >&2; exit 1; }
