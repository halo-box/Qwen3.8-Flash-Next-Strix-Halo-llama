<h1 align="center">Qwen3.8-Flash-Next on AMD Strix Halo (strix-llama.cpp)</h1>

Serve **Qwen3.8-Flash-Next** (180B total, 6B active) from one AMD Strix Halo (Ryzen AI Max+ 395, Radeon 8060S /
gfx1151, 128 GB) through an OpenAI-compatible API, with
[halo-box/strix-llama.cpp](https://github.com/halo-box/strix-llama.cpp) in Docker. Two backends, each with its own
image: **ROCm 10.1** with pwilkin's retained-PM4 runtime (the default), or **Vulkan** (Mesa RADV).

- Model: [`agentionai/Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-GGUF`](https://huggingface.co/agentionai/Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-GGUF)
  `v2/` (87 GiB) and its [MTP head](https://huggingface.co/agentionai/Qwen3.8-Flash-Next-MTP-ROCmFP4-FAST-GGUF) (2.3 GiB)
- Engine: strix-llama.cpp `bed1b8a14` + [#151](https://github.com/halo-box/strix-llama.cpp/pull/151)
- 8 requests at once, one q8_0 KV pool of 262,144 tokens shared between them; any one request can use the full
  262,144-token window
- MTP speculative decoding (3 drafts)

## Quick start

```bash
git clone https://github.com/halo-box/Qwen3.8-Flash-Next-Strix-Halo-llama.git
cd Qwen3.8-Flash-Next-Strix-Halo-llama
./start.sh
```

That is all. The first run downloads the model (~90 GiB into `~/models/qwen38-flash-next`, resumable, checked
against Hugging Face's sha256), builds the engine image, loads the model and prints
`Qwen3.8-Flash-Next is now LIVE on http://127.0.0.1:8080/v1`. Later starts take about 30 seconds.
`BACKEND=vulkan ./start.sh` runs the Vulkan build instead; `./stop.sh` stops the server.

Any OpenAI client works with that base URL and the model `Qwen3.8-Flash-Next`. The model thinks before answering:
give replies enough `max_tokens`, or send `"chat_template_kwargs": {"enable_thinking": false}`.

## Performance

One Strix Halo (Minisforum MS-S1 MAX, kernel 7.0, `amd_iommu=off`, tuned `accelerator-performance`), the recipe's
defaults, through the OpenAI API. Prefill: a fresh prompt each run. Decode: *code* is "Write a Python quicksort with
docstring and tests." at temperature 0, *prose* is "Explain why the sky is blue in a few paragraphs." with the
default sampling, 256 tokens, median of 5 runs at one request. Measured with `bench/speed.py`, which follows the method
of [Mia's AI Lab](https://github.com/MiaAI-Lab) recipes.

### ROCm (`BACKEND=rocm`, default)

**Prefill**

| Prompt | Prefill speed | Time to first token |
| ---: | ---: | ---: |
| 8k | 764 tok/s | 11.0 s |
| 16k | 843 tok/s | 19.7 s |
| 32k | 739 tok/s | 44.6 s |
| 64k | 598 tok/s | 110 s |
| 128k | 417 tok/s | 315 s |

**Decode** (tok/s)

| Requests at once | Code, aggregate | Code, per request | Prose, aggregate | Prose, per request |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 44.0 | 47.8 | 34.3 | 37.2 |
| 2 | 44.2 | 25.6 | 39.2 | 22.6 |
| 4 | 74.5 | 20.6 | 52.2 | 14.9 |
| 8 | 71.9 | 10.4 | 67.1 | 9.7 |

### Vulkan (`BACKEND=vulkan`)

**Prefill**

| Prompt | Prefill speed | Time to first token |
| ---: | ---: | ---: |
| 8k | 627 tok/s | 13.3 s |
| 16k | 609 tok/s | 27.1 s |
| 32k | 512 tok/s | 64.4 s |
| 64k | 393 tok/s | 167 s |
| 128k | 278 tok/s | 471 s |

**Decode** (tok/s)

| Requests at once | Code, aggregate | Code, per request | Prose, aggregate | Prose, per request |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 46.4 | 51.3 | 37.9 | 41.7 |
| 2 | 51.2 | 28.7 | 46.7 | 25.4 |
| 4 | 52.7 | 14.8 | 45.5 | 12.5 |
| 8 | 64.3 | 9.1 | 59.3 | 8.5 |

**Which one:** Vulkan decodes a single request 7-12% faster (code 51.3 against 47.8 tok/s, prose 41.7 against
37.2). ROCm prefills 22-52% faster, the gap growing with prompt length, and serves 41% more tokens with four
requests at once (74.5 against 52.7 tok/s on code). For one interactive user on short prompts, Vulkan; for long
contexts, agents that re-read large prompts, or several users, ROCm.

## Requirements

- An AMD Strix Halo with 128 GB, nothing else large on the GPU
- Linux kernel 7.0 or newer, with GTT raised on the kernel command line (measured at `ttm.pages_limit=27262976`,
  104 GiB; the server uses 93 GiB on Vulkan, 96 GiB on ROCm)
- Docker, with your user in the `docker` group
- ~95 GB of free disk

## Configuration

Settings live in [`scripts/config.sh`](scripts/config.sh). Override them in the environment (`PARALLEL=4 ./start.sh`)
or a `.env` file next to `start.sh` (`KEY=value` lines). Arguments after `--` go to `llama-server` last
(`./start.sh restart -- --ctx-checkpoints 8`), and any `LLAMA_ARG_*` variable is passed through.

| Variable | Default | |
| --- | --- | --- |
| `BACKEND` | `rocm` | `rocm` or `vulkan` |
| `MODEL_DIR` | `~/models/qwen38-flash-next` | where the two model files are |
| `HOST` / `PORT` / `API_KEY` | `127.0.0.1` / `8080` / none | set `API_KEY` before `HOST=0.0.0.0` |
| `PARALLEL` | `8` | requests decoded at once |
| `CONTEXT` / `CONTEXT_PER_SLOT` | `262144` / `262144` | shared KV pool; most one request may use |
| `KV_DTYPE` | `q8_0` | KV cache type |
| `UBATCH` | ROCm `4096`, Vulkan `2048` | prompt batch size |
| `MTP` / `MTP_DRAFT_N` | `1` / `3` | MTP speculative decoding |
| `MMPROJ_FILE` | none | a vision projector in `MODEL_DIR` enables images |

## Notes

- **Settings:** ubatch 4096 is where ROCm prefill stops improving (2048 is ~18% slower); larger ones do not fit
  beside a 262k pool. 3 MTP drafts beat 2, 4 and 5; MTP costs ~12% of prefill and nearly doubles decode. q8_0 KV halves
  the cache's memory at no measured speed cost (Agention; Nathanw1014).
- **Never load with `--load-mode mmap`** on this hardware: on Vulkan a later load in the same boot fails
  (`Couldn't update BO_VA (-12)` in `dmesg`) and can wedge the GPU driver until a reboot; on ROCm KFD refuses it.
  The recipe reads weights with `--load-mode none`, and the 22 GB n-gram table row by row (`--lazy-mode on-direct`).
- **Don't start the server while building images.** A load during heavy disk writes has failed with a lost device.
- `start.sh` refuses to start while another `llama-server` exists, and stops a load that brings GTT within 1 GiB of
  the kernel's limit: past it the kernel swaps GPU memory and can OOM-kill other services.

## Credits

[CREDITS.md](CREDITS.md) lists where each file, setting and idea came from: the engine
([halo-box/strix-llama.cpp](https://github.com/halo-box/strix-llama.cpp) on
[llama.cpp](https://github.com/ggml-org/llama.cpp)), the containers (adapted from
[kyuz0/amd-strix-halo-toolboxes](https://github.com/kyuz0/amd-strix-halo-toolboxes), with
[pwilkin/rocm-systems](https://github.com/pwilkin/rocm-systems)), the model (Qwen, quantized by
[Agention](https://agention.ai)), and the shape of this repository (after [Mia's AI Lab](https://github.com/MiaAI-Lab)
and [claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo](https://github.com/claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo)).
