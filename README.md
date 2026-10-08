<h1 align="center">Qwen3.8-Flash-Next on AMD Strix Halo (strix-llama.cpp)</h1>

Serve **Qwen3.8-Flash-Next** (180B total, 6B active) from one AMD Strix Halo (Ryzen AI Max+ 395, Radeon 8060S /
gfx1151, 128 GB) through an OpenAI-compatible API, with
[halo-box/strix-llama.cpp](https://github.com/halo-box/strix-llama.cpp) in Docker. Two backends, each with its own
image: **ROCm 10.1** with pwilkin's retained-PM4 runtime (the default), or **Vulkan** (Mesa RADV).

- Model: [`agentionai/Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-GGUF`](https://huggingface.co/agentionai/Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-GGUF)
  `v2/` (87 GiB), its [MTP head](https://huggingface.co/agentionai/Qwen3.8-Flash-Next-MTP-ROCmFP4-FAST-GGUF) (2.3 GiB)
  and vision tower (0.9 GiB)
- Engine: strix-llama.cpp `bed1b8a14` + [#151](https://github.com/halo-box/strix-llama.cpp/pull/151) + a
  [fix](docker/patches/fattn-mask-kv-max-partial-tile.patch) for long prompts on ROCm
- **Several requests at once, each with its own full 262,144-token window**: as many as fit, chosen at start
  (4 on ROCm and 2 on Vulkan with 104 GiB of GTT, see [Memory](#memory))
- MTP speculative decoding, q8_0 KV cache, image input, tool calls, streaming

## Quick start

```bash
git clone https://github.com/halo-box/Qwen3.8-Flash-Next-Strix-Halo-llama.git
cd Qwen3.8-Flash-Next-Strix-Halo-llama
./setup.sh      # checks the host and offers to fix it (GTT kernel parameters need a reboot)
./start.sh
```

That is all. The first run downloads the model (~91 GiB into `~/models/qwen38-flash-next`, resumable, checked
against Hugging Face's sha256), gets the engine image, loads the model, runs a smoke test and prints
`Qwen3.8-Flash-Next is now LIVE on http://127.0.0.1:8080/v1`. Later starts take about a minute.
`BACKEND=vulkan ./start.sh` runs the Vulkan build instead.

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "Qwen3.8-Flash-Next",
  "messages": [{"role": "user", "content": "Write a Python fibonacci function."}],
  "max_tokens": 2000
}'
```

Any OpenAI client works with `base_url="http://127.0.0.1:8080/v1"` and the model `Qwen3.8-Flash-Next`. The model
thinks before it answers (`reasoning_content`): give replies enough `max_tokens`, or send
`"chat_template_kwargs": {"enable_thinking": false}`.

```bash
./start.sh restart                       # after changing a setting; a bad setting leaves the running server alone
./stop.sh                                # stop the server and free the GPU memory
docker logs -f qwen38-flash-next-strix   # server log
curl -s http://127.0.0.1:8080/metrics    # Prometheus metrics
```

## Performance

One Strix Halo (Minisforum MS-S1 MAX, kernel 7.0, 104 GiB of GTT, `amd_iommu=off`, tuned
`accelerator-performance`), the recipe's defaults, through the OpenAI API. Prefill: a fresh prompt each run. Decode:
*code* is "Write a Python quicksort with docstring and tests." at temperature 0, *prose* is "Explain why the sky is
blue in a few paragraphs." with the default sampling; 256 tokens, median of 5 runs at one request. Measured with
`bench/speed.py`, which follows the method of [Mia's AI Lab](https://github.com/MiaAI-Lab) recipes.

### ROCm (`BACKEND=rocm`, default: 4 slots of 262k)

ROCMTABLE

### Vulkan (`BACKEND=vulkan`: 2 slots of 262k)

VULKANTABLE

**Which one:** WHICHONE

## Images

The model's own vision tower is on by default (`VISION=0` turns it off). Send images as OpenAI content parts:

```bash
IMG=$(base64 -w0 photo.jpg)
curl -s http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "Qwen3.8-Flash-Next",
  "messages": [{"role": "user", "content": [
    {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,'"$IMG"'"}},
    {"type": "text", "text": "What is in this picture?"}]}],
  "max_tokens": 2000
}'
```

## Memory

GTT is the memory the kernel lets the GPU use, carved out of the machine's RAM. What this recipe takes, measured at
its defaults (q8_0 KV, ubatch 2048, MTP, vision, 262,144-token windows):

| | One slot | Each further slot |
| --- | ---: | ---: |
| ROCm | 87.4 GiB | +4.2 GiB |
| Vulkan | 91.0 GiB | +6.3 GiB |

Most of a slot's cost is not its KV cache but the compute buffers that scale with batch size × window: that is
why the batch size is 2048 (4096 prefills ~8% faster on ROCm but leaves room for half the slots).

`PARALLEL=auto` (the default) starts as many slots as fit under the GTT limit while keeping `RAM_RESERVE_GIB` (10)
of RAM for the system:

| GTT limit (`ttm.pages_limit`) | ROCm | Vulkan |
| --- | ---: | ---: |
| 104 GiB (`27262976`) | 4 slots | 2 slots |
| 120 GiB (`31457280`, what `./setup.sh` sets) | 6 slots (projected) | 4 slots (projected) |

A setting that does not fit is refused before anything loads, with the number of slots that would. A slot's cost
grows with its window (one slot: 75.8 GiB at 64k, 92.6 GiB at 262k with ubatch 4096), so shorter windows
(`CONTEXT_PER_SLOT`) fit more slots.

## What `./start.sh` does

1. **Setup**: `scripts/prepare.sh` downloads whatever model file is missing and gets the image: it pulls the
   prebuilt one, or builds `docker/Dockerfile.rocm` / `docker/Dockerfile.vulkan`. Image tags are a hash of
   everything that goes into the image, so changing a pin can never reuse a stale one.
2. **Memory plan**: picks the slot count, or refuses a setting that does not fit.
3. **Launch**: checks the arguments with `llama-server` in a throwaway container before touching a running server,
   refuses to start while another `llama-server` exists, and starts the container.
4. **Loading**: shows how much of the expected memory has loaded, and stops the server if GTT comes within 1 GiB of
   the kernel's limit (past it the kernel swaps GPU memory and can OOM-kill other services).
5. **Smoke test**: one chat completion, then the LIVE message.

`FOREGROUND=1 ./start.sh` stays attached to the server's log and exits with its exit code, for a systemd unit.

## Configuration

Settings live in [`scripts/config.sh`](scripts/config.sh). Override them in the environment (`PARALLEL=2 ./start.sh`)
or a `.env` file next to `start.sh` (`KEY=value` lines). Arguments after `--` go to `llama-server` last
(`./start.sh restart -- --verbose`), and any `LLAMA_ARG_*` variable is passed through.

| Variable | Default | |
| --- | --- | --- |
| `BACKEND` | `rocm` | `rocm` or `vulkan` |
| `MODEL_DIR` | `~/models/qwen38-flash-next` | where the model files are, or are downloaded to |
| `HOST` / `PORT` / `API_KEY` | `127.0.0.1` / `8080` / none | set `API_KEY` before `HOST=0.0.0.0` |
| `PARALLEL` | `auto` | requests served at once, each with its own window |
| `CONTEXT_PER_SLOT` | `262144` | tokens each request may use (prompt and reply) |
| `KV_DTYPE` | `q8_0` | KV cache type |
| `UBATCH` | `2048` | prompt batch size |
| `MTP` / `MTP_DRAFT_N` | `1` / `3` | MTP speculative decoding |
| `VISION` | `1` | image input |
| `CTX_CHECKPOINTS` / `CACHE_RAM` | `4` / `0` | per-slot state checkpoints and host prompt cache; both grow host RAM over time |

## Testing

```bash
python3 tests/check.py              # chat, streaming, tool call, image, a request over 262k refused
python3 tests/check.py --window     # also one request near the full window (~20 min)
python3 tests/check.py --long 4     # also 4 concurrent ~200k-token requests (slow)
```

## Notes

- **Defaults, measured:** 3 MTP drafts beat 2, 4, 5 and adaptive drafting; MTP costs ~12% of prefill and nearly
  doubles decode. Stopping drafts under load (`--spec-draft-max-slots`) or below a draft probability
  (`--spec-draft-p-min`) measured slower. q8_0 KV halves the cache's memory at no measured speed cost (Agention;
  Nathanw1014).
- **Never load with `--load-mode mmap`** on this hardware: on Vulkan a later load in the same boot fails
  (`Couldn't update BO_VA (-12)` in `dmesg`) and can wedge the GPU driver until a reboot; on ROCm KFD refuses it.
  The recipe reads weights with `--load-mode none`, and the 22 GB n-gram table row by row (`--lazy-mode on-direct`).
- **Don't start the server while building images.** A load during heavy disk writes has failed with a lost device.

## Credits

[CREDITS.md](CREDITS.md) lists where each file, setting and idea came from: the engine
([halo-box/strix-llama.cpp](https://github.com/halo-box/strix-llama.cpp) on
[llama.cpp](https://github.com/ggml-org/llama.cpp)), the containers (adapted from
[kyuz0/amd-strix-halo-toolboxes](https://github.com/kyuz0/amd-strix-halo-toolboxes), with
[pwilkin/rocm-systems](https://github.com/pwilkin/rocm-systems)), the model (Qwen, quantized by
[Agention](https://agention.ai)), host setup (after
[claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo](https://github.com/claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo)) and
the shape of this repository (after [Mia's AI Lab](https://github.com/MiaAI-Lab)).
