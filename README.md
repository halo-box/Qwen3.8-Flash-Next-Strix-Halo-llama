<h1 align="center">Qwen3.8-Flash-Next on AMD Strix Halo (strix-llama.cpp)</h1>

Serve **Qwen3.8-Flash-Next** (180B total, 6B active) from a single AMD Strix Halo box (Ryzen AI Max+ 395, Radeon
8060S / gfx1151, 128 GB) through an OpenAI-compatible API. It runs
[halo-box/strix-llama.cpp](https://github.com/halo-box/strix-llama.cpp), the Strix Halo fork of llama.cpp, in Docker,
with the model's own MTP head drafting tokens and several requests decoded at once, each able to use the model's full
262,144-token window.

- Checkpoint: [`agentionai/Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-GGUF`](https://huggingface.co/agentionai/Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-GGUF)
  `v2/` (ROCmFP4-FAST, imatrix, 87 GiB) with the matching
  [MTP head](https://huggingface.co/agentionai/Qwen3.8-Flash-Next-MTP-ROCmFP4-FAST-GGUF) (2.3 GiB)
- Engine: strix-llama.cpp `4c6ccf20e` + [#151](https://github.com/halo-box/strix-llama.cpp/pull/151), Vulkan (Mesa
  RADV 26.2) or ROCm 10.1 (TheRock), see [Vulkan or ROCm](#vulkan-or-rocm)
- API model id: `Qwen3.8-Flash-Next`
- KV cache: one q8_0 pool shared by all slots (`--kv-unified`), each slot capped at 262,144 tokens
  (`--kv-unified-per-slot`)
- One command: `./start.sh` builds or pulls the image on the first run, starts the server, waits for it and
  smoke-tests it; `./stop.sh` stops it

## Performance

> Being measured. The tables below are filled from `bench/` runs on one Strix Halo (Minisforum MS-S1 MAX, 128 GB,
> kernel 7.0, `amd_iommu=off`, tuned `accelerator-performance`), through the OpenAI API, with the recipe's defaults.

**Decode** (llama-benchy, prose, 2,048-token prompt, 256 generated)

| Concurrent requests | Aggregate | Per request | Time to first token |
| ---: | ---: | ---: | ---: |
| 1 | | | |
| 2 | | | |
| 4 | | | |
| 8 | | | |

**Prefill**

| Prompt | Prefill speed | Time to first token |
| ---: | ---: | ---: |
| 8k | | |
| 32k | | |
| 128k | | |

## Requirements

- An AMD Strix Halo machine with 128 GB, nothing else large on the GPU
- Linux kernel 7.0 or newer, with the GPU allowed most of the memory: `ttm.pages_limit` (in 4 KiB pages) on the
  kernel command line. This recipe is measured at `ttm.pages_limit=27262976` (104 GiB of GTT); see
  [KV pool and memory](#kv-pool-and-memory)
- Docker, and your user in the `docker` group. The containers get `/dev/dri` (and `/dev/kfd` for ROCm) and the host's
  `render` and `video` groups
- ~95 GB of disk for the model, ~3 GB (Vulkan) or ~8 GB (ROCm) for the image

## Quick start

```bash
git clone https://github.com/halo-box/Qwen3.8-Flash-Next-Strix-Halo-llama.git
cd Qwen3.8-Flash-Next-Strix-Halo-llama

# Get the model (~96 GB, resumable)
mkdir -p ~/models/qwen38-flash-next && cd ~/models/qwen38-flash-next
curl -L -C - -O https://huggingface.co/agentionai/Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-GGUF/resolve/main/v2/Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-v2.gguf
curl -L -C - -O https://huggingface.co/agentionai/Qwen3.8-Flash-Next-MTP-ROCmFP4-FAST-GGUF/resolve/main/Qwen3.8-Flash-Next-MTP-ROCmFP4-FAST.gguf
cd -

echo "MODEL_DIR=$HOME/models/qwen38-flash-next" > .env
./start.sh
```

The first run pulls the image (or builds it, a few minutes), loads the weights (about a minute from a warm page
cache), runs one chat completion and prints `Qwen3.8-Flash-Next is now LIVE on http://127.0.0.1:8080/v1`.

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "Qwen3.8-Flash-Next",
  "messages": [{"role": "user", "content": "Write a Python fibonacci function."}],
  "max_tokens": 2000
}'
```

Any OpenAI client works with `base_url = "http://127.0.0.1:8080/v1"`. The model thinks before it answers, so give
replies enough `max_tokens`, or send `"chat_template_kwargs": {"enable_thinking": false}`.

```bash
./start.sh restart                  # restart, e.g. after changing a setting
./start.sh --print                  # show the docker command without running it
./stop.sh                           # stop the server and free the GPU memory
docker logs -f qwen38-flash-next-strix
curl -s http://127.0.0.1:8080/metrics
```

## What `start.sh` does

1. **Setup**: checks the model files, and runs `scripts/prepare.sh` if the image is missing. `prepare.sh` pulls the
   prebuilt image, or builds `docker/Dockerfile.vulkan` / `docker/Dockerfile.rocm` locally.
2. **Arguments**: assembles the `llama-server` command from `scripts/config.sh`.
3. **Launch**: refuses to start while another `llama-server` still exists, has `llama-server` validate the arguments
   in a throwaway container, flushes pending disk writes, and starts the container.
4. **Loading**: waits for `/health`, and stops the server if GTT comes within `GTT_MARGIN_GIB` of the kernel's limit
   (past it, the kernel swaps GPU memory and OOM-kills host services instead of failing the allocation).
5. **Smoke test**: one chat completion, then the LIVE message.

## Vulkan or ROCm

> Being measured: Vulkan (Mesa RADV 26.2.3), ROCm 10.1, ROCm 10.1 with pwilkin's retained-PM4 runtime, and ROCm 10.0
> with retained PM4 as the baseline kyuz0 published (43.9 tok/s decode), all at the same engine commit. Each must pass
> `bench/quality.sh` (wikitext-2 perplexity, and identical greedy output for 8 concurrent requests) before its speed
> counts.

Switch with `BACKEND=` in `.env`: `vulkan`, `rocm10.1`, `rocm10.1-pm4` or `rocm10.0-pm4`.

## KV pool and memory

Only 12 of the model's 48 layers are full attention, so its KV cache is small: about 12.75 KiB a token at q8_0
(Agention's figure), ~3.2 GiB for one full 262,144-token window. The 22.4 GB n-gram (PLE) table is not loaded to the
GPU at all: `--lazy-mode on-direct` reads the rows it needs from the page cache.

`CONTEXT` is the size of the one pool all slots share; `CONTEXT_PER_SLOT` (262,144) caps any single request at the
model's native window, so one long request cannot run past it however large the pool is.

> Being measured: GTT used at each pool size, and the largest pool that fits under 104 GiB.

## Configuration

Every setting lives in [`scripts/config.sh`](scripts/config.sh) and can be overridden from the environment
(`PARALLEL=4 ./start.sh`) or a `.env` file next to `start.sh` (`KEY=value` lines, read as data, never sourced; the
environment wins). Arguments after `--` go to `llama-server` last, so they win
(`./start.sh restart -- --spec-draft-max-slots 4`).

| Variable | Default | Meaning |
| --- | --- | --- |
| `BACKEND` | `vulkan` | `vulkan`, `rocm10.1`, `rocm10.1-pm4` or `rocm10.0-pm4` |
| `MODEL_DIR` | `~/models/qwen38-flash-next` | directory holding the model files, mounted read-only |
| `MODEL_FILE` / `MTP_FILE` | the two Agention files | file names inside `MODEL_DIR` |
| `MMPROJ_FILE` | empty | a vision projector in `MODEL_DIR` enables image input |
| `HOST` / `PORT` | `127.0.0.1` / `8080` | where the API listens; `0.0.0.0` publishes it on the LAN |
| `API_KEY` | empty | require `Authorization: Bearer <key>`; set it before using `HOST=0.0.0.0` |
| `PARALLEL` | `8` | requests decoded together (slots) |
| `CONTEXT` | `262144` | KV pool shared by all slots, in tokens |
| `CONTEXT_PER_SLOT` | `262144` | most context one request may use |
| `KV_UNIFIED` | `1` | `0` gives each slot its own `CONTEXT / PARALLEL` instead of one shared pool |
| `KV_DTYPE` | `q8_0` | KV cache type for the model and the draft head |
| `BATCH` / `UBATCH` | `2048` / `2048` | prompt batch sizes |
| `LAZY_MODE` / `LOAD_MODE` | `on-direct` / `none` | the n-gram table is read row by row from disk, never loaded to the GPU; weights are read into GPU memory, not memory-mapped (see Troubleshooting) |
| `MTP` | `1` | `0` serves without the draft head |
| `SPEC_TYPE` / `MTP_DRAFT_N` / `MTP_ADAPTIVE` | `draft-mtp` / `3` / `0` | speculative decoding |
| `SPEC_N_RS_SEQ` | `-1` | recurrent-state snapshots kept per slot for fast draft rollback ([#147](https://github.com/halo-box/strix-llama.cpp/pull/147)); `-1` follows `MTP_DRAFT_N`, lower saves memory |
| `TEMPERATURE` / `TOP_P` / `TOP_K` | `1.0` / `0.95` / `20` | default sampling (Qwen's thinking-mode values); a request's own values win |
| `GTT_MARGIN_GIB` | `1` | stop loading when GTT gets this close to the kernel's limit |
| `EXTRA_ARGS` | empty | extra `llama-server` arguments |
| `LLAMA_PRS` | `151:3cb54eb…` | open pull requests merged into the image at build time |

`GGML_*`, `AMD_*`, `HSA_*`, `RADV_*` and `DEBUG_HIP_*` variables in the environment are passed into the container.

## Benchmarks

The scripts that produce every number above are in [`bench/`](bench):

| Script | What it measures |
| --- | --- |
| `bench/speed.py` | prefill (8k to 128k prompts) and decode (code and prose tasks, optionally at several concurrency levels) against the running server, with Mia's AI Lab's method |
| `bench/sweep.sh PLAN` | `speed.py` against each configuration in a plan file (`bench/plans/`), one after another on an idle machine |
| `bench/quality.sh BACKEND` | wikitext-2 perplexity, one sequence against four batched (the gfx1151 HIP bug) |
| `bench/kernel.sh BACKEND` | raw prefill and decode with `llama-bench`, no server |
| `bench/fit.sh BACKEND` | the largest KV pool that loads, growing it a step at a time |

Results land in `results/` (not tracked). Run them on an idle machine.

## Troubleshooting

- **Don't load with `--load-mode mmap`.** On Vulkan it works on a fresh boot and later loads fail: `Couldn't update
  BO_VA (-12)` in `dmesg`, then a lost device or a `llama-server` stuck in `D` state that only a reboot clears. On ROCm,
  KFD refuses to map the whole file (`SVM mapping failed, exceeds resident system memory limit`). The recipe uses
  `none`.
- **Don't load the model while building images or doing heavy disk writes.** A load that starts while gigabytes of
  writes are still being flushed can fail its GPU allocations (`Couldn't update BO_VA (-12)` in `dmesg`); the server
  crashes, and the amdgpu driver can oops while cleaning up, leaving a `llama-server` stuck in `D` state that only a
  reboot clears. `start.sh` runs `sync` first and refuses to start while another `llama-server` exists.
- **A pool that does not fit hangs instead of failing.** Past the GTT limit the kernel swaps GPU memory and can
  OOM-kill other services. Grow `CONTEXT` a step at a time (`bench/fit.sh`), and keep `GTT_MARGIN_GIB` set.
- **ROCm: never set `GGML_CUDA_ENABLE_UNIFIED_MEMORY`**: under retained PM4 it corrupts output (kyuz0).
- **ROCm: wrong output with several requests at once** is the gfx1151 HIP async bug the strix-llama.cpp README
  describes; `HIP_LAUNCH_BLOCKING=1 ./start.sh restart` works around it, at a speed cost. `bench/quality.sh` checks
  for it.

## Credits

This recipe stands on others' work; [CREDITS.md](CREDITS.md) lists where each file, setting and idea came from. In
short: the engine is [halo-box/strix-llama.cpp](https://github.com/halo-box/strix-llama.cpp) on
[llama.cpp](https://github.com/ggml-org/llama.cpp); the containers are adapted from
[kyuz0/amd-strix-halo-toolboxes](https://github.com/kyuz0/amd-strix-halo-toolboxes) with
[pwilkin/rocm-systems](https://github.com/pwilkin/rocm-systems); the model is Qwen's, quantized by
[Agention](https://agention.ai); and the shape of this repository and README follows
[Mia's AI Lab](https://github.com/MiaAI-Lab) recipes and
[claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo](https://github.com/claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo).
