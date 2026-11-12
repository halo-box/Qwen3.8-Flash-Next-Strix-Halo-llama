<h1 align="center">Qwen3.8-Flash-Next on AMD Strix Halo (strix-llama.cpp)</h1>

Serve **Qwen3.8-Flash-Next** (180B total, 6B active), as AgentionAI's Signal fine-tune, from one AMD Strix Halo
(Ryzen AI Max, Radeon 8060S / gfx1151, 128 GB) through an OpenAI-compatible API, with
[halo-box/strix-llama.cpp](https://github.com/halo-box/strix-llama.cpp)'s own Docker images. Nothing is built on your
machine. One switch picks the backend: `BACKEND=vulkan` (the default) or `BACKEND=rocm`.

- Model: [`agentionai/Signal-3.8-Flash-Next-GGUF`](https://huggingface.co/agentionai/Signal-3.8-Flash-Next-GGUF)
  `AP-Q4_K_XL` (94 GiB, 70 GiB of it on the GPU), its multi-token-prediction head
  [`Qwen3.8-Flash-Next-MTP-Q8_0`](https://huggingface.co/agentionai/Qwen3.8-Flash-Next-MTP-Q8_0-GGUF) and the
  vision tower. Signal is a self-distilled fine-tune of Qwen3.8-Flash-Next: the same weights' knowledge, about a
  quarter fewer reasoning tokens, and the MTP head agrees with it 90% of the time against 69% for the base model
  (model card, not measured here).
- Engine: strix-llama.cpp `server-vulkan` / `server-rocm` images, build `b12389`, master `075de20cf`
  ([v1.0.0](https://github.com/halo-box/strix-llama.cpp/releases/tag/v1.0.0) and the maskless quantized-KV attention
  of [#270](https://github.com/halo-box/strix-llama.cpp/pull/270) / [#271](https://github.com/halo-box/strix-llama.cpp/pull/271)), pinned by digest
- API model id: `Qwen3.8-Flash-Next`
- **4 requests at once, each with its own full 262,144-token window** (Vulkan, q8_0 KV cache: 92.8 GiB on the GPU);
  `BACKEND=rocm` serves 2 (f16 KV, 91.7 GiB). See [Memory](#memory).
- MTP speculative decoding, image input, tool calls, streaming

## Performance

The defaults (`./start.sh`, 4 × 262,144-token windows on Vulkan, 2 on ROCm), one Strix Halo (GMKtec EVO-X2, Ryzen
AI Max+ 395, 128 GB, Ubuntu 26.04 kernel 7.0.0-43, 104 GiB of GTT, `amd_iommu=off`, tuned `accelerator-performance`),
measured with [sparkDash](https://github.com/MiaAI-Lab/sparkDash)'s Decode and Prefill benchmarks on the same machine,
the way [Mia's AI Lab](https://github.com/MiaAI-Lab) measures its Qwen3.8-Flash-Next recipes, so the numbers can be
compared with theirs. Prose: temperature 0.7, thinking on. Code: temperature 0, thinking off, a different Python task
per stream. 400 tokens a stream, each decode run three times and the median shown. Vulkan's decode rows are with
`--spec-draft-max-slots 2` (the default), its prefill rows from the same build and settings before that flag, which a
single-request prefill does not use.

How the figures are taken (sparkDash `da20ac5`, `DecodeBench` and `PrefillBench`):

- **Per request** is the mean of each stream's `(completion_tokens - 1) / (time of the last token - time of the first)`,
  so time to first token is not in it.
- **Aggregate** is every stream's decode tokens over the window from the first stream's first token to the last
  stream's last token. It is not the sum of the per-request speeds.
- **TTFT** is the mean time to the first token, client clock.
- **Prefill** sends a cold prompt with a unique prefix per run, and its speed is llama-server's own prompt timing. The
  token count includes the chat template.

MTP drafts pay only when they are accepted, so decode speed depends on the text: a figure from another harness is
comparable only with the same prompts, sampling and thinking setting. A single prose run varies by 10-25% with
sampling on, hence the median of three. `bench/sparkdash.py` runs it (see [Benchmarks](#benchmarks)).

### Vulkan (`BACKEND=vulkan`, default: 4 × 262k, q8_0 KV)

**Decode, prose**

| Concurrent requests | Aggregate | Per request | TTFT |
| ---: | ---: | ---: | ---: |
| 1 | 34.9 tok/s | 34.9 tok/s | 94 ms |
| 2 | 46.0 tok/s | 24.2 tok/s | 447 ms |
| 4 | 61.5 tok/s | 15.8 tok/s | 626 ms |

**Decode, code**

| Concurrent requests | Aggregate | Per request | TTFT |
| ---: | ---: | ---: | ---: |
| 1 | 57.0 tok/s | 57.0 tok/s | 315 ms |
| 2 | 48.7 tok/s | 24.6 tok/s | 432 ms |
| 4 | 62.2 tok/s | 15.8 tok/s | 782 ms |

**Prefill** (cold prompts)

| Prompt tokens | Prefill | TTFT |
| ---: | ---: | ---: |
| 4,134 | 1,066 tok/s | 3.89 s |
| 8,230 | 1,097 tok/s | 7.52 s |
| 16,425 | 1,112 tok/s | 14.80 s |
| 32,808 | 1,098 tok/s | 29.91 s |
| 65,576 | 1,057 tok/s | 62.06 s |
| 131,108 | 987 tok/s | 132.97 s |

### ROCm (`BACKEND=rocm`: 2 × 262k, f16 KV)

**Decode, prose**

| Concurrent requests | Aggregate | Per request | TTFT |
| ---: | ---: | ---: | ---: |
| 1 | 31.3 tok/s | 31.3 tok/s | 98 ms |
| 2 | 47.4 tok/s | 24.2 tok/s | 707 ms |

**Decode, code**

| Concurrent requests | Aggregate | Per request | TTFT |
| ---: | ---: | ---: | ---: |
| 1 | 53.8 tok/s | 53.8 tok/s | 94 ms |
| 2 | 65.8 tok/s | 33.2 tok/s | 432 ms |

**Prefill** (cold prompts)

| Prompt tokens | Prefill | TTFT |
| ---: | ---: | ---: |
| 4,136 | 1,001 tok/s | 4.14 s |
| 8,230 | 1,004 tok/s | 8.21 s |
| 16,419 | 999 tok/s | 16.46 s |
| 32,805 | 985 tok/s | 33.34 s |
| 65,573 | 958 tok/s | 68.46 s |
| 131,109 | 922 tok/s | 142.35 s |

### Checks on the current build

Run on this machine at the defaults with the pinned images, all passing:

| | Vulkan, 4 × 262k | ROCm, 2 × 262k |
| --- | --- | --- |
| `tests/check.py`: chat, streaming, a required tool call, image input | ok | ok |
| a prompt of exactly 262,144 tokens is refused (HTTP 400) | ok | ok |
| `--window`: 262,131 prompt + 13 reply tokens, the window filled exactly, the last prompt chunk a partial tile | served in 305 s | served in 308 s |
| `--long`: every request ~200k tokens at once | 4 × 200k in 863 s | 2 × 200k in 451 s |
| GTT peak / lowest usable RAM (`MemAvailable - CmaFree`) over the whole run | 94.9 / 17.0 GiB | 92.9 / 19.9 GiB |
| amdgpu or OOM errors in the kernel log | none | none |

### Tested on

| Host | Distro, kernel | GTT | Result |
| --- | --- | --- | --- |
| GMKtec EVO-X2 (Ryzen AI Max+ 395, 128 GB) | Ubuntu 26.04, 7.0.0-43 | 104 GiB | every check above; a fresh clone runs the Quick start as written |

Covered without the hardware: `tests/host_test.sh` (the gfx1151 found among other GPUs through KFD's topology),
`tests/bootloader_test.sh` (the kernel-parameter step on rpm-ostree, kernelstub, grubby, Debian and Arch GRUB, and
systemd-boot), and `./setup.sh --check` in Ubuntu 26.04, Debian 13, Fedora 44 and Arch containers. Not yet run: other
vendors' Strix Halo boxes, other distros and kernels on the hardware, a second GPU in the same machine. The memory plan
reads each host's own GTT limit, `MemTotal` and `CmaFree`, so a host with more usable memory gets a larger budget,
not a different configuration. To add a host, open an issue with the output of `./setup.sh --check`, `./start.sh`
and `python3 tests/check.py --window`.

## Requirements

- Any Strix Halo (Ryzen AI Max, gfx1151) with 128 GB, whatever the vendor. A second GPU (eGPU, discrete card) can
  stay in: the recipe finds the gfx1151 through KFD and gives the container only its render node.
- The BIOS UMA / dedicated graphics memory at its minimum: the GPU uses GTT, which a carve-out takes from.
- GTT raised to `MemTotal` minus 10 GiB (`ttm.pages_limit`, `amdgpu.gttsize`; Mia's DGX Spark recipe keeps 9 GiB
  free) and `amd_iommu=off`. `./setup.sh` works the values out from your RAM and adds them with rpm-ostree (Bazzite,
  Silverblue), kernelstub (Pop!_OS), grubby (Fedora), GRUB (Debian, Ubuntu, Arch) or systemd-boot, asking first;
  anything else is done by hand.
- Linux with the amdgpu driver. Tested on kernel 7.0 (Ubuntu 26.04); older kernels are untested.
- Docker, with your user in the `docker` group; `curl`, `python3`, `sha256sum` and `pgrep` on the host.
- ~100 GB of free disk for the model files, plus the image: 0.3 GiB (Vulkan) or 8.6 GiB (ROCm) to download.

## Quick start

```bash
git clone https://github.com/halo-box/Qwen3.8-Flash-Next-Strix-Halo-llama.git
cd Qwen3.8-Flash-Next-Strix-Halo-llama
./setup.sh      # checks the host and offers to fix it (GTT kernel parameters need a reboot)
./start.sh      # BACKEND=rocm ./start.sh for ROCm
```

The first run downloads the model (~99 GiB into `~/models/qwen38-flash-next`, resumable, checked against Hugging
Face's sha256), pulls the engine image, loads the model, runs a smoke test and prints
`Qwen3.8-Flash-Next is now LIVE on http://127.0.0.1:8080/v1`. Later starts take about half a minute.

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "Qwen3.8-Flash-Next",
  "messages": [{"role": "user", "content": "Write a Python fibonacci function."}],
  "max_tokens": 2000
}'
```

Any OpenAI client works with `base_url="http://127.0.0.1:8080/v1"` and the model `Qwen3.8-Flash-Next`. The model
thinks before it answers (`reasoning_content`): give replies enough `max_tokens`, or send
`"chat_template_kwargs": {"enable_thinking": false}`. The server's default sampling is Signal's: temperature 0.6,
top-p 0.95, top-k 20, min-p 0.05; a request's own values win.

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
2. **Memory plan**: works out what the configuration takes on the GPU (below) and refuses one that does not fit,
   with the number of requests that would.
3. **Launch**: checks the arguments with `llama-server` in a throwaway container before touching a running server,
   refuses to start while another `llama-server` exists, and starts the container.
4. **Loading**: shows how much of the expected memory has loaded, and kills the server at once if GTT passes the
   budget or the host's usable memory drops under 4 GiB.
5. **Smoke test**: one chat completion, then the LIVE message.

`FOREGROUND=1 ./start.sh` stays attached to the server's log and exits with its exit code, for a systemd unit.

## Memory

GTT is the memory the kernel lets the GPU use, carved out of the machine's RAM. Measured with `bench/memory.sh`
(MTP and vision on, the 22 GB n-gram table read from disk, ubatch 2048):

| Backend, KV cache | 1 × 262k | 2 × 262k | 4 × 262k | 4 × 131k | 5 × 131k |
| --- | ---: | ---: | ---: | ---: | ---: |
| Vulkan, q8_0 | 78.8 GiB | 84.0 GiB | **92.8 GiB** | | |
| ROCm, f16 | 83.7 GiB | **91.7 GiB** | does not fit | 92.6 GiB | 95.6 GiB |

Each 262,144-token window costs 4.3 GiB with q8_0 and 7.9 GiB with f16; the model takes 70.1 GiB and the compute
buffers 6-9 GiB whatever the number of requests. ROCm keeps f16 because its QSA attention kernels take only f16 K/V:
with q8_0 it falls back to a masked route whose buffers grow by ~14 GiB per 262k window (20.7 GiB of compute for one
window, 44.6 GiB requested for four).

The memory plan in `start.sh` uses these figures (`MODEL_GIB`, `COMPUTE_GIB`, `KV_GIB_PER_262K`) and refuses a
configuration over the least of: the GTT limit minus 2 GiB, `MemTotal` minus 10 GiB, and `MemTotal` minus `CmaFree`
minus 8 GiB. The last one matters on kernels that count free RAM as CMA with no CMA area (`nr_free_cma` > 0,
`CmaTotal: 0`; 5-13 GiB on Ubuntu 7.0.0-43): GPU pages cannot use that memory, and a GPU that filled GTT to its limit
there ran the kernel out of memory. `./setup.sh` warns when it sees it. `PARALLEL=5` fits 5 × 262k on Vulkan
(~97 GiB) when the budget allows; shorter windows (`CONTEXT_PER_SLOT`) fit more requests.

## Configuration

Settings live in [`scripts/config.sh`](scripts/config.sh). Override them in the environment (`PARALLEL=2 ./start.sh`)
or a `.env` file next to `start.sh` (`KEY=value` lines, read as data, never sourced). Arguments after `--` go to
`llama-server` last (`./start.sh restart -- --verbose`), and any `LLAMA_ARG_*` variable is passed through.

| Variable | Default | |
| --- | --- | --- |
| `BACKEND` | `vulkan` | `vulkan` or `rocm`; the image, KV cache type and number of requests follow it |
| `IMAGE` | per backend | the engine image |
| `SERVER_BIN` | none | `llama-server`'s path in an `IMAGE` whose entrypoint is not it |
| `MODEL_DIR` | `~/models/qwen38-flash-next` | where the model files are, or are downloaded to |
| `HOST` / `PORT` / `API_KEY` | `127.0.0.1` / `8080` / none | set `API_KEY` before `HOST=0.0.0.0` |
| `PARALLEL` | `4` (Vulkan), `2` (ROCm) | requests served at once, each with its own window; `auto` = as many as fit |
| `CONTEXT_PER_SLOT` | `262144` | tokens each request may use (prompt and reply) |
| `KV_DTYPE` | `q8_0` (Vulkan), `f16` (ROCm) | KV cache type |
| `UBATCH` | `2048` | prompt batch size |
| `MTP` / `MTP_DRAFT_N` | `1` / `3` | MTP speculative decoding |
| `SPEC_DRAFT_MAX_SLOTS` | `2` | draft only while at most this many requests generate (0 = always) |
| `VISION` | `1` | image input |
| `TEMPERATURE` / `TOP_P` / `TOP_K` / `MIN_P` | `0.6` / `0.95` / `20` / `0.05` | default sampling |
| `CTX_CHECKPOINTS` / `CACHE_RAM` | `4` / `0` | per-slot state checkpoints and host prompt cache; both grow host RAM over time |

## How the defaults were chosen

One request, 262,144-token window, MTP on, unless a row says otherwise; each from a sparkDash run on this machine.

| Choice | Measured | Kept |
| --- | --- | --- |
| Q4_K weights, not ROCmFP4 | ROCm, q8_0 KV, 40k window, ubatch 4096: UD-Q4_K_XL prefills 1,241 / 925 tok/s at 8k / 32k against 893 / 714 for Agention's ROCmFP4, and decodes 31.5 / 50.4 (prose / code) against 35.2 / 55.8 | a Q4_K_XL: on long prompts the prefill gain finishes a request first |
| Signal AP-Q4_K_XL, not unsloth UD-Q4_K_XL | 70.1 against 79.4 GiB on the GPU (a 262k window with room to spare) and, per its card, 90% MTP acceptance | Signal |
| f16 KV on ROCm | ROCmFP4, ROCm: f16 decodes 42.4 / 55.1 tok/s and prefills 894 tok/s at 32k in 82.0 GiB; q8_0 decodes 32.8 / 53.6, prefills 653 tok/s at 32k and takes 99.2 GiB (masked route) | f16 on ROCm |
| q8_0 KV on Vulkan | with #271 the compute buffers stay at 6.8-8.5 GiB from 1 to 4 windows, so each 262k window costs 4.3 GiB | q8_0 on Vulkan |
| Vulkan as the default | the only backend where 4 × 262k fits; with UD-Q4_K_XL at the v1.0.0 release recipe's settings it decodes 40.6 / 54.4 tok/s against ROCm's 30.5 / 50.0, ROCm prefilling 9% faster | Vulkan |
| 3 MTP drafts, not 4 | Signal, ROCm, two runs each: 3 drafts 36.1 / 53.9 tok/s, 4 drafts 29.9 / 55.4 | 3 |
| Agention's Q8_0 MTP head | the head Signal's card names; unsloth's Q8_0 head and Agention's ROCmFP4 head decode the same (33.5 / 52.4 against 32.8 / 53.6) | Agention Q8_0 |
| No retained-PM4 ROCm runtime | kyuz0's PM4 build of the same commit (ROCm 10.0) against the official image (ROCm 10.1), one run each: decode +9% / +8%, prefill -2 to -3% | not used: one run, and a second image |
| No flash-attention mask patch | earlier versions patched a GPU fault on a ~241k prompt whose last chunk is a partial tile; on this build, ROCm and Vulkan serve a 262,131-token prompt (a partial last tile) without it | not carried |
| Draft only while at most 2 requests generate | Vulkan, 4 × 262k, aggregate tok/s at 1 / 2 / 4 requests: prose 36.1 / 44.0 / 46.6 drafting always, 34.9 / 46.0 / 61.5 with `--spec-draft-max-slots 2`; code 53.9 / 48.0 / 65.8 and 57.0 / 48.7 / 62.2. With 1, code at two requests fell to 28.3 | 2 |
| `--no-spec-draft-backend-sampling` | Signal's card: draft sampling on the backend skips min-p for accepted drafts, so a repetition can run away | on |

## Checks

```bash
python3 tests/check.py              # chat, streaming, tool call, image, a prompt the size of the window refused
python3 tests/check.py --window     # also a request that fills the window exactly is served
python3 tests/check.py --long 4     # also 4 concurrent ~200k-token requests
tests/host_test.sh                  # GPU detection against fake KFD topologies (no GPU needed)
tests/bootloader_test.sh            # setup.sh's kernel-parameter step on each boot loader, in containers
```

## Benchmarks

```bash
python3 bench/sparkdash.py --label vulkan --clients 1,2,4   # against the running server
bench/sweep.sh bench/plans/readme.txt                       # restart with each configuration, then measure
bench/memory.sh bench/plans/memory-signal-vulkan.txt        # what each configuration takes on the GPU
```

`bench/sparkdash.py` runs sparkDash (`sparkdash:da20ac5`) in a container on the host network, registers this machine
as a local unit and drives its benchmarks through sparkDash's API. Build the image once with
`docker build -t sparkdash:da20ac5 https://github.com/MiaAI-Lab/sparkDash.git#da20ac5b4940bd9ff349fdb020e32252dd71fa21`.
Results go to `results/sparkdash/<label>.md` and `.json`.

## Notes

- **Never load with `--load-mode mmap`** on this hardware: on Vulkan a later load in the same boot fails
  (`Couldn't update BO_VA (-12)` in `dmesg`) and can wedge the GPU driver until a reboot; on ROCm KFD refuses it.
  The recipe reads weights with `--load-mode none`, and the 22 GB n-gram table row by row (`--lazy-mode on-direct`).
- **Do not run a configuration past the memory plan** (`FORCE=1`) on Vulkan: it fills GTT pages as they are first
  touched, past any allocation-time check, and near the GTT limit the kernel OOM-kills host services before anything
  can stop it. ROCm refuses an allocation that does not fit.

## Repository layout

| Path | |
| --- | --- |
| `setup.sh` | host checks and fixes (GPU, BIOS carve-out, host tools, Docker, kernel, GTT parameters, tuned) |
| `start.sh` / `stop.sh` | serve and stop |
| `scripts/config.sh` | every setting, with `.env` and environment overrides |
| `scripts/prepare.sh` | model download and sha256 check, image pull |
| `scripts/host.sh` | finds the gfx1151 GPU (render node, GTT counters) through KFD's topology |
| `tests/check.py` | functional checks against the running server |
| `tests/host_test.sh` | `scripts/host.sh` against fake topologies (no GPU needed) |
| `tests/bootloader_test.sh` | `setup.sh`'s kernel-parameter step on each boot loader, in throwaway containers |
| `bench/sparkdash.py`, `bench/sweep.sh`, `bench/memory.sh`, `bench/plans/` | speed and memory measurements |

## Credits

[CREDITS.md](CREDITS.md) lists where each file, setting and idea came from: the engine and its images
([halo-box/strix-llama.cpp](https://github.com/halo-box/strix-llama.cpp) on [llama.cpp](https://github.com/ggml-org/llama.cpp)),
the model (Qwen; Signal and its MTP head by [AgentionAI](https://agention.ai)), the benchmark
([sparkDash](https://github.com/MiaAI-Lab/sparkDash)), host setup (after
[claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo](https://github.com/claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo))
and the shape of this repository (after [Mia's AI Lab](https://github.com/MiaAI-Lab)).
