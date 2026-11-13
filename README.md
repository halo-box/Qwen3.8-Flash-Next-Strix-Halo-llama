<h1 align="center">Qwen3.8-Flash-Next on AMD Strix Halo (strix-llama.cpp)</h1>

Serve **Qwen3.8-Flash-Next** (180B total, 6B active) from one AMD Strix Halo
(Ryzen AI Max, Radeon 8060S / gfx1151, 128 GB) through an OpenAI-compatible API, with
[halo-box/strix-llama.cpp](https://github.com/halo-box/strix-llama.cpp)'s own Docker images. Nothing is built on your
machine. One switch picks the backend: `BACKEND=vulkan` (the default) or `BACKEND=rocm`.

- Model: [`unsloth/Qwen3.8-Flash-Next-GGUF`](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF)
  `UD-Q4_K_XL` (104 GiB in four files, 79 GiB of it on the GPU: the 28 GB n-gram table is read from disk), its
  multi-token-prediction head `MTP/mtp-Qwen3.8-Flash-Next-Q8_0.gguf` and the vision tower: the model and head of
  the [v1.0.0 release recipe](https://github.com/halo-box/strix-llama.cpp/releases/tag/v1.0.0)
- Engine: strix-llama.cpp `server-vulkan` / `server-rocm` images, build `b12389`, master `075de20cf`
  ([v1.0.0](https://github.com/halo-box/strix-llama.cpp/releases/tag/v1.0.0) and the maskless quantized-KV attention
  of [#270](https://github.com/halo-box/strix-llama.cpp/pull/270) / [#271](https://github.com/halo-box/strix-llama.cpp/pull/271)), pinned by digest
- API model id: `Qwen3.8-Flash-Next`
- **3 requests at once, each with its own full 262,144-token window** (Vulkan, q8_0 KV cache: 102.0 GiB on the GPU
  at its peak, under full load); `BACKEND=rocm` serves 1 (f16 KV). See [Memory](#memory).
- MTP speculative decoding, image input, tool calls, streaming

## Performance

The defaults (`./start.sh`: 3 × 262,144-token windows on Vulkan, 1 on ROCm), one Strix Halo (GMKtec EVO-X2, Ryzen
AI Max+ 395, 128 GB, Ubuntu 26.04 kernel 7.0.0-43, 107 GiB of GTT, `amd_iommu=off`, tuned `accelerator-performance`),
measured with [sparkDash](https://github.com/MiaAI-Lab/sparkDash)'s Decode and Prefill benchmarks on the same machine,
the way [Mia's AI Lab](https://github.com/MiaAI-Lab) measures its Qwen3.8-Flash-Next recipes, so the numbers can be
compared with theirs. Prose: temperature 0.7, thinking on. Code: temperature 0, thinking off, a different Python task
per stream. 400 tokens a stream, each decode run three times and the median shown.

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

### Vulkan (`BACKEND=vulkan`, default: 3 × 262k, q8_0 KV)

**Decode, prose**

| Concurrent requests | Aggregate | Per request | TTFT |
| ---: | ---: | ---: | ---: |
| 1 | 37.9 tok/s | 37.9 tok/s | 98 ms |
| 2 | 49.5 tok/s | 25.2 tok/s | 423 ms |
| 3 | 50.1 tok/s | 16.8 tok/s | 467 ms |

**Decode, code**

| Concurrent requests | Aggregate | Per request | TTFT |
| ---: | ---: | ---: | ---: |
| 1 | 52.5 tok/s | 52.5 tok/s | 315 ms |
| 2 | 64.2 tok/s | 33.0 tok/s | 420 ms |
| 3 | 50.5 tok/s | 17.0 tok/s | 507 ms |

**Prefill** (cold prompts)

| Prompt tokens | Prefill | TTFT |
| ---: | ---: | ---: |
| 4,134 | 1,200 tok/s | 3.45 s |
| 8,231 | 1,209 tok/s | 6.82 s |
| 16,423 | 1,224 tok/s | 13.44 s |
| 32,806 | 1,234 tok/s | 26.62 s |
| 65,575 | 1,184 tok/s | 55.41 s |
| 131,111 | 1,101 tok/s | 119.15 s |

### ROCm (`BACKEND=rocm`: 1 × 262k, f16 KV)

**Decode, prose**

| Concurrent requests | Aggregate | Per request | TTFT |
| ---: | ---: | ---: | ---: |
| 1 | 31.4 tok/s | 31.4 tok/s | 98 ms |

**Decode, code**

| Concurrent requests | Aggregate | Per request | TTFT |
| ---: | ---: | ---: | ---: |
| 1 | 48.4 tok/s | 48.4 tok/s | 353 ms |

**Prefill** (cold prompts)

| Prompt tokens | Prefill | TTFT |
| ---: | ---: | ---: |
| 4,136 | 1,358 tok/s | 3.06 s |
| 8,225 | 1,410 tok/s | 5.84 s |
| 16,424 | 1,421 tok/s | 11.57 s |
| 32,807 | 1,410 tok/s | 23.28 s |
| 65,572 | 1,393 tok/s | 47.13 s |
| 131,111 | 1,363 tok/s | 96.26 s |

### Checks on the current build

Run on this machine at the defaults with the pinned images, all passing:

| | Vulkan, 3 × 262k | ROCm, 1 × 262k |
| --- | --- | --- |
| `tests/check.py`: chat, streaming, a required tool call, image input | ok | ok |
| a prompt of exactly 262,144 tokens is refused (HTTP 400) | ok | ok |
| `--window`: 262,131 prompt + 13 reply tokens, the window filled exactly, the last prompt chunk a partial tile | served in 272 s | served in 202 s |
| `--long`: every request ~196k tokens (3/4 of its window) at once | 3 × 196k in 555 s | 1 × 196k in 146 s |
| GTT peak / lowest usable RAM (`MemAvailable - CmaFree`) under that load | 102.0 / 8.6 GiB | 95.3 / 18.4 GiB |
| amdgpu or OOM errors in the kernel log | none | none |

### Tested on

| Host | Distro, kernel | GTT | Result |
| --- | --- | --- | --- |
| GMKtec EVO-X2 (Ryzen AI Max+ 395, 128 GB) | Ubuntu 26.04, 7.0.0-43 | 107 GiB | every check above; a fresh clone runs the Quick start as written |

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
- ~115 GB of free disk for the model files, plus the image: 0.3 GiB (Vulkan) or 8.6 GiB (ROCm) to download.

## Quick start

```bash
git clone https://github.com/halo-box/Qwen3.8-Flash-Next-Strix-Halo-llama.git
cd Qwen3.8-Flash-Next-Strix-Halo-llama
./setup.sh      # checks the host and offers to fix it (GTT kernel parameters need a reboot)
./start.sh      # BACKEND=rocm ./start.sh for ROCm
```

The first run downloads the model (~109 GiB into `~/models/qwen38-flash-next`, resumable, checked against Hugging
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
`"chat_template_kwargs": {"enable_thinking": false}`. The server's default sampling is the model's own: temperature
1.0, top-p 0.95, top-k 20; a request's own values win.

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

## Serving on the network and watching it

The server listens on `127.0.0.1:8080`: only the machine itself reaches it. To serve other machines, set an API key
and the address to listen on, then restart:

```bash
API_KEY=$(openssl rand -hex 24) HOST=0.0.0.0 ./start.sh restart     # or put both in .env
```

No firewall rule is needed to open the port, and one does not close it: Docker publishes the port with its own
rules, ahead of ufw (Ubuntu; off by default) and firewalld (Fedora; on by default). To limit who can connect, set
`HOST` to one of the machine's addresses instead of `0.0.0.0`, or add a rule to Docker's own chain, for example only
the local network:

```bash
sudo iptables -I DOCKER-USER -p tcp --dport 8080 ! -s 192.168.0.0/16 -j DROP
```

The server's own dashboard is at `http://<host>:8080/dashboard`: decode and prefill speed live and over the last 10
minutes, MTP acceptance, each request's progress and KV use, the last requests and the configuration. It asks for
the API key when one is set. `http://<host>:8080/metrics` serves the same counters to Prometheus.

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
and under load (UD-Q4_K_XL, MTP and vision on, the 28 GB n-gram table read from disk, ubatch 4096):

| Backend, KV cache | Requests × window | GTT once loaded | GTT peak under full load |
| --- | --- | ---: | ---: |
| Vulkan, q8_0 | **3 × 262,144** (default) | 97.4 GiB | **102.0 GiB** |
| Vulkan, q8_0 | 4 × 196,608 | 98.2 GiB | |
| Vulkan, q8_0 | 4 × 212,992 | 99.3 GiB | over 102.5 GiB, stopped |
| ROCm, f16 | **1 × 262,144** (default) | 93.5 GiB | **95.3 GiB** |

The model takes 79.4 GiB on the GPU, each 262,144-token window 4.3 GiB with q8_0 and 7.8 GiB with f16, and the
compute buffers 7-10 GiB whatever the number of requests. Vulkan fills its pages as the prompts grow, so its peak is
~4.6 GiB above what it holds once loaded; the plan in `start.sh` is calibrated to that peak (`MODEL_GIB`,
`COMPUTE_GIB`, `KV_GIB_PER_262K`). ROCm keeps f16 because its QSA attention kernels take only f16 K/V: with q8_0 it
falls back to a masked route whose buffers grow by ~14 GiB per 262k window.

`start.sh` refuses a configuration over the least of: the GTT limit minus 2 GiB, `MemTotal` minus 10 GiB (Mia's DGX
Spark recipe keeps 9 GiB free), and `MemTotal` minus `CmaFree` minus 6 GiB. The last one matters on this kernel:
the page allocator types 7-14 GiB of free RAM as CMA (`nr_free_cma`, `/proc/pagetypeinfo`) with no CMA area
reserved (`0K cma-reserved` at boot, `CmaTotal: 0`). GPU pages cannot use those blocks, and with 12 GiB of them a
UD-Q4_K_XL server died at 99 GiB of GTT, well under its 104 GiB limit. `./setup.sh` warns when it sees CMA-free
memory. Shorter windows (`CONTEXT_PER_SLOT`, or `auto` for the largest that fits) fit more requests.

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
| `PARALLEL` | `3` (Vulkan), `1` (ROCm) | requests served at once, each with its own window; `auto` = as many as fit |
| `CONTEXT_PER_SLOT` | `262144` | tokens each request may use (prompt and reply); `auto` = the largest window that fits `PARALLEL` requests, up to 262,144 |
| `KV_DTYPE` | `q8_0` (Vulkan), `f16` (ROCm) | KV cache type |
| `UBATCH` | `4096` | prompt batch size |
| `MTP` / `MTP_DRAFT_N` | `1` / `3` | MTP speculative decoding |
| `SPEC_DRAFT_MAX_SLOTS` | `2` | draft only while at most this many requests generate (0 = always) |
| `VISION` | `1` | image input |
| `TEMPERATURE` / `TOP_P` / `TOP_K` / `MIN_P` | `1.0` / `0.95` / `20` / `0` | default sampling (the model's own) |
| `CTX_CHECKPOINTS` / `CACHE_RAM` | `4` / `0` | per-slot state checkpoints and host prompt cache; both grow host RAM over time |

## How the defaults were chosen

One request, 262,144-token window, MTP on, unless a row says otherwise; each from a sparkDash run on this machine.

| Choice | Measured | Kept |
| --- | --- | --- |
| ubatch 4096 | ROCm, Signal, 1 request, 262k: 1,077 / 1,080 tok/s at 8k / 32k against 1,032 / 1,014 with 2048; the 262k window costs nothing against 40k (1,078 / 1,081) | 4096, as the release recipe |
| Q4_K weights, not ROCmFP4 | ROCm, q8_0 KV, 40k window, ubatch 4096: UD-Q4_K_XL prefills 1,241 / 925 tok/s at 8k / 32k against 893 / 714 for Agention's ROCmFP4, and decodes 31.5 / 50.4 (prose / code) against 35.2 / 55.8 | a Q4_K_XL: on long prompts the prefill gain finishes a request first |
| UD-Q4_K_XL, not AgentionAI's Signal AP-Q4_K_XL | ROCm, 1 request, 40k, ubatch 4096, f16 KV: UD-Q4_K_XL prefills 1,433 / 1,424 tok/s at 8k / 32k, Signal 1,078 / 1,081. Signal takes 9 GiB less on the GPU (70.1 against 79.4), enough for 4 × 262k; it was the default until this like-for-like run | UD-Q4_K_XL: prefill over the last 54k of window |
| f16 KV on ROCm | ROCmFP4, ROCm: f16 decodes 42.4 / 55.1 tok/s and prefills 894 tok/s at 32k in 82.0 GiB; q8_0 decodes 32.8 / 53.6, prefills 653 tok/s at 32k and takes 99.2 GiB (masked route) | f16 on ROCm |
| q8_0 KV on Vulkan | with #271 the compute buffers stay flat from 1 to 4 windows (6.8-8.5 GiB, Signal), so each 262k window costs 4.3 GiB against 7.8 with f16 | q8_0 on Vulkan |
| Vulkan as the default | the only backend where 3 × 262k fits (ROCm: 1). UD-Q4_K_XL at the defaults: Vulkan decodes 37.9 / 52.5 tok/s and prefills 1,234 tok/s at 32k, ROCm 31.4 / 48.4 and 1,410 | Vulkan |
| 3 MTP drafts, not 4 | ROCm, two runs each (Signal AP-Q4_K_XL): 3 drafts 36.1 / 53.9 tok/s, 4 drafts 29.9 / 55.4 | 3 |
| unsloth's Q8_0 MTP head | the release recipe's head; unsloth's Q8_0 head and Agention's ROCmFP4 head decode the same (33.5 / 52.4 against 32.8 / 53.6 tok/s) | unsloth Q8_0 |
| No retained-PM4 ROCm runtime | kyuz0's PM4 build of the same commit (ROCm 10.0) against the official image (ROCm 10.1), one run each: decode +9% / +8%, prefill -2 to -3% | not used: one run, and a second image |
| No flash-attention mask patch | earlier versions patched a GPU fault on a ~241k prompt whose last chunk is a partial tile; on this build, ROCm and Vulkan serve a 262,131-token prompt (a partial last tile) without it | not carried |
| Draft only while at most 2 requests generate | Vulkan, Signal AP-Q4_K_XL, 4 × 262k, aggregate tok/s at 1 / 2 / 4 requests: prose 36.1 / 44.0 / 46.6 drafting always, 34.9 / 46.0 / 61.5 with `--spec-draft-max-slots 2`; code 53.9 / 48.0 / 65.8 and 57.0 / 48.7 / 62.2. With 1, code at two requests fell to 28.3 | 2 |
| `--no-spec-draft-backend-sampling` | AgentionAI's model cards: draft sampling on the backend skips min-p (and the rest of the sampler) for accepted drafts, so a repetition can run away when a client sends min-p | on |

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
python3 bench/sparkdash.py --label vulkan --clients 1,2,3   # against the running server
bench/sweep.sh bench/plans/readme.txt                       # restart with each configuration, then measure
bench/memory.sh bench/plans/memory.txt                      # what each configuration takes on the GPU
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
the model (Qwen; quantized by [Unsloth](https://unsloth.ai)), the benchmark
([sparkDash](https://github.com/MiaAI-Lab/sparkDash)), host setup (after
[claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo](https://github.com/claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo))
and the shape of this repository (after [Mia's AI Lab](https://github.com/MiaAI-Lab)).
