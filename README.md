<h1 align="center">Qwen3.8-Flash-Next on AMD Strix Halo (strix-llama.cpp)</h1>

Serve **Qwen3.8-Flash-Next** (180B total, 6B active) from one AMD Strix Halo (Ryzen AI Max+ 395, Radeon 8060S /
gfx1151, 128 GB) through an OpenAI-compatible API, with [halo-box/strix-llama.cpp](https://github.com/halo-box/strix-llama.cpp)'s
own Docker images. One switch picks the backend: `BACKEND=rocm` (ROCm 10.1, the default) or `BACKEND=vulkan` (Mesa RADV).
Nothing is built on your machine.

- Model: [`agentionai/Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-GGUF`](https://huggingface.co/agentionai/Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-GGUF)
  `v2/` (87 GiB), its [MTP head](https://huggingface.co/agentionai/Qwen3.8-Flash-Next-MTP-ROCmFP4-FAST-GGUF) (2.3 GiB)
  and vision tower (0.9 GiB)
- Engine: strix-llama.cpp's own `server-rocm-b12385` / `server-vulkan-b12385` images, pinned by digest: master
  `8a44a73b3`, [v1.0.0](https://github.com/halo-box/strix-llama.cpp/releases/tag/v1.0.0) plus 34 commits
- API model id: `Qwen3.8-Flash-Next`
- **Several requests at once, each with its own full 262,144-token window**: as many as fit, chosen at start (see
  [Memory](#memory))
- MTP speculative decoding, q8_0 KV cache, image input, tool calls, streaming

## Performance

**Pending: not measured on the pinned images yet.**

What the tables will hold: the recipe's defaults (262,144-token windows, `PARALLEL=auto`, q8_0 KV, vision on, MTP
drafts), one Strix Halo (Minisforum MS-S1 MAX, kernel 7.0, 104 GiB of GTT, `amd_iommu=off`, tuned
`accelerator-performance`), measured with [sparkDash](https://github.com/MiaAI-Lab/sparkDash)'s Decode and Prefill
benchmarks on the same machine as the server, the way [Mia's AI Lab](https://github.com/MiaAI-Lab) measures its
Qwen3.8-Flash-Next recipes, so the numbers can be compared with theirs. Prose: temperature 0.7, thinking on. Code:
temperature 0, thinking off, a different Python task per stream. 400 tokens a stream.

How the figures are taken (sparkDash `da20ac5`, `DecodeBench` and `PrefillBench`):

- **Per request** is the mean of each stream's `(completion_tokens - 1) / (time of the last token - time of the first)`,
  so time to first token is not in it.
- **Aggregate** is every stream's decode tokens over the window from the first stream's first token to the last
  stream's last token. It is not the sum of the per-request speeds.
- **TTFT** is the mean time to the first token, client clock.
- **Prefill** sends a cold prompt with a unique prefix per run, and its speed is llama-server's own prompt timing. The
  token count includes the chat template.

MTP drafts pay only when they are accepted, so decode speed depends on the text: a figure from another harness is
comparable only with the same prompts, sampling and thinking setting. `bench/sparkdash.py` runs it (see
[Benchmarks](#benchmarks)).

### ROCm (`BACKEND=rocm`, default)

Pending.

### Vulkan (`BACKEND=vulkan`)

Pending.

### Checks on the current build

Pending: `tests/check.py --window` and `--long` on each backend.

## Requirements

- Any Strix Halo (Ryzen AI Max, gfx1151) with 128 GB, whatever the vendor. A second GPU (eGPU, discrete card) can
  stay in: the recipe finds the gfx1151 through KFD and gives the container only its render node.
- The BIOS UMA / dedicated graphics memory at its minimum: the GPU uses GTT, which a carve-out takes from.
- GTT raised to the machine's RAM minus 8 GiB (`ttm.pages_limit`, `amdgpu.gttsize`) and `amd_iommu=off`. `./setup.sh`
  works the values out from your RAM and adds them with rpm-ostree (Bazzite, Silverblue), kernelstub (Pop!_OS),
  grubby (Fedora), GRUB (Debian, Ubuntu, Arch) or systemd-boot, asking first; anything else is done by hand.
- Linux with the amdgpu driver. Tested on kernel 7.0 (Ubuntu 26.04); older kernels are untested.
- Docker, with your user in the `docker` group.
- ~95 GB of free disk for the model files, plus the image: 0.3 GiB (Vulkan) or 8.6 GiB (ROCm) to download.

## Quick start

```bash
git clone https://github.com/halo-box/Qwen3.8-Flash-Next-Strix-Halo-llama.git
cd Qwen3.8-Flash-Next-Strix-Halo-llama
./setup.sh      # checks the host and offers to fix it (GTT kernel parameters need a reboot)
./start.sh      # BACKEND=vulkan ./start.sh for Vulkan
```

The first run downloads the model (~91 GiB into `~/models/qwen38-flash-next`, resumable, checked against Hugging
Face's sha256), pulls the engine image, loads the model, runs a smoke test and prints
`Qwen3.8-Flash-Next is now LIVE on http://127.0.0.1:8080/v1`. Later starts take about a minute.

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
./start.sh --print                       # print the docker command and exit
./stop.sh                                # stop the server and free the GPU memory
docker logs -f qwen38-flash-next-strix   # server log
curl -s http://127.0.0.1:8080/metrics    # Prometheus metrics
```

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

## What `./start.sh` does

1. **Setup**: `scripts/prepare.sh` downloads whatever model file is missing and pulls the engine image.
2. **Memory plan**: picks the slot count, or refuses a setting that does not fit.
3. **Launch**: checks the arguments with `llama-server` in a throwaway container before touching a running server,
   refuses to start while another `llama-server` exists, and starts the container.
4. **Loading**: shows how much of the expected memory has loaded, and stops the server if GTT comes within 1 GiB of
   the kernel's limit (past it the kernel swaps GPU memory and can OOM-kill other services).
5. **Smoke test**: one chat completion, then the LIVE message.

`FOREGROUND=1 ./start.sh` stays attached to the server's log and exits with its exit code, for a systemd unit.

## Memory

GTT is the memory the kernel lets the GPU use, carved out of the machine's RAM. **Pending: the per-slot costs are
being measured again on the v1.0.0 images** (#216 changed how multi-slot compute memory is sized). Most of a slot's
cost is not its KV cache but the compute buffers that scale with batch size × window.

`PARALLEL=auto` (the default) starts as many slots as fit under the GTT limit while keeping `RAM_RESERVE_GIB` (10) of
RAM for the system. A setting that does not fit is refused before anything loads, with the number of slots that
would. Shorter windows (`CONTEXT_PER_SLOT`) fit more slots.

## Configuration

Settings live in [`scripts/config.sh`](scripts/config.sh). Override them in the environment (`PARALLEL=2 ./start.sh`)
or a `.env` file next to `start.sh` (`KEY=value` lines, read as data, never sourced). Arguments after `--` go to
`llama-server` last (`./start.sh restart -- --verbose`), and any `LLAMA_ARG_*` variable is passed through.

| Variable | Default | |
| --- | --- | --- |
| `BACKEND` | `rocm` | `rocm` or `vulkan` |
| `IMAGE` | per backend | the engine image |
| `SERVER_BIN` | none | `llama-server`'s path in an `IMAGE` whose entrypoint is not it |
| `MODEL_DIR` | `~/models/qwen38-flash-next` | where the model files are, or are downloaded to |
| `HOST` / `PORT` / `API_KEY` | `127.0.0.1` / `8080` / none | set `API_KEY` before `HOST=0.0.0.0` |
| `PARALLEL` | `auto` | requests served at once, each with its own window |
| `CONTEXT_PER_SLOT` | `262144` | tokens each request may use (prompt and reply) |
| `KV_DTYPE` | `q8_0` | KV cache type |
| `UBATCH` | `2048` | prompt batch size |
| `MTP` / `MTP_DRAFT_N` | `1` / `3` | MTP speculative decoding |
| `VISION` | `1` | image input |
| `CTX_CHECKPOINTS` / `CACHE_RAM` | `4` / `0` | per-slot state checkpoints and host prompt cache; both grow host RAM over time |

## Checks

```bash
python3 tests/check.py              # chat, streaming, tool call, image, a prompt the size of the window refused
python3 tests/check.py --window     # also a request that fills the window exactly is served (~20 min)
python3 tests/check.py --long 4     # also 4 concurrent ~200k-token requests (slow)
```

## Benchmarks

```bash
python3 bench/sparkdash.py --label rocm --clients 1,2,4     # against the running server
bench/sweep.sh bench/plans/readme.txt                       # restart with each configuration, then measure
```

`bench/sparkdash.py` runs sparkDash (`sparkdash:da20ac5`) in a container on the host network, registers this machine
as a local unit and drives its benchmarks through sparkDash's API. Build the image once with
`docker build -t sparkdash:da20ac5 https://github.com/MiaAI-Lab/sparkDash.git#da20ac5b4940bd9ff349fdb020e32252dd71fa21`.
Results go to `results/sparkdash/<label>.md` and `.json`.

## Notes

- **Never load with `--load-mode mmap`** on this hardware: on Vulkan a later load in the same boot fails
  (`Couldn't update BO_VA (-12)` in `dmesg`) and can wedge the GPU driver until a reboot; on ROCm KFD refuses it.
  The recipe reads weights with `--load-mode none`, and the 22 GB n-gram table row by row (`--lazy-mode on-direct`).
- **3 MTP drafts** beat 2, 4, 5 and adaptive drafting on the earlier build; stopping drafts under load
  (`--spec-draft-max-slots`) or below a draft probability (`--spec-draft-p-min`) measured slower. Pending a re-check
  on v1.0.0.

## Repository layout

| Path | |
| --- | --- |
| `setup.sh` | host checks and fixes (Docker, GPU access, kernel, GTT parameters, tuned) |
| `start.sh` / `stop.sh` | serve and stop |
| `scripts/config.sh` | every setting, with `.env` and environment overrides |
| `scripts/prepare.sh` | model download and sha256 check, image pull |
| `scripts/host.sh` | finds the gfx1151 GPU (render node, GTT counters) through KFD's topology |
| `tests/check.py` | functional checks against the running server |
| `tests/host_test.sh` | `scripts/host.sh` against fake topologies (no GPU needed) |
| `tests/bootloader_test.sh` | `setup.sh`'s kernel-parameter step on each boot loader, in throwaway containers |
| `bench/sparkdash.py`, `bench/sweep.sh`, `bench/plans/` | speed measurements |

## Credits

[CREDITS.md](CREDITS.md) lists where each file, setting and idea came from: the engine and its images
([halo-box/strix-llama.cpp](https://github.com/halo-box/strix-llama.cpp) on [llama.cpp](https://github.com/ggml-org/llama.cpp)),
the model (Qwen, quantized by [Agention](https://agention.ai)), the benchmark ([sparkDash](https://github.com/MiaAI-Lab/sparkDash)),
host setup (after [claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo](https://github.com/claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo))
and the shape of this repository (after [Mia's AI Lab](https://github.com/MiaAI-Lab)).
