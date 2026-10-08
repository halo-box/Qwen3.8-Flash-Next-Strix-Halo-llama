# How the defaults were chosen

Every number here was measured on one Strix Halo (Minisforum MS-S1 MAX, Ryzen AI Max+ 395, 128 GB, kernel 7.0,
`amd_iommu=off`, `ttm.pages_limit` 104 GiB, tuned `accelerator-performance`) on 2026-10-08, with the model and
draft head this recipe ships: Agention's ROCmFP4-FAST imatrix v2 and its ROCmFP4 MTP head. KV cache is q8_0
throughout. Engine: strix-llama.cpp `4c6ccf20e` + #151.

Two tools, two kinds of number:

- `llama-bench` (raw engine, no server, no MTP): pwilkin's Flash-Next protocol, `-p 16384 -n 128 -r 2`.
- `bench/speed.py` (through the recipe's own server, MTP on unless noted): Mia's AI Lab's method. Prefill is a
  fresh synthetic prompt per run; decode is "code" (a Python quicksort, temperature 0) and "prose" (why the sky is
  blue, default sampling), 256 tokens, median of 5 runs at one request. Speeds are the server's own timings.

## Backend

Recipe defaults of the time (ubatch 2048, 8 slots, 262k pool, MTP draft 3), one request, `bench/speed.py`:

| Backend | Prefill 8k | 16k | 32k | 64k | 128k | Decode, code | Decode, prose |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| ROCm 10.1 + retained PM4 | 787 | 795 | 713 | 565 | 394 | 47.8 | 40.5 |
| Vulkan (RADV 26.2.3) | 584 | | | | | 49.5 | 36.4 |

ROCm wins prefill by a third and prose decode by a tenth; Vulkan is ~2 tok/s ahead on code. ROCm is the default.

## Batch size

`llama-bench`, ROCm 10.1 + PM4, 16k prompt:

| `-b` / `-ub` | Prefill (tok/s) |
| ---: | ---: |
| 2048 | 817 |
| 4096 | 967 |
| 8192 | 951 |
| 16384 | 961 |
| 24576 | 965 |

Prefill is flat from 4096 up. Through the server, 8192 and larger do not start: the compute buffer is sized for the
262k context (34 GiB at 16384) and does not fit. **4096** is the default.

A build with the Vulkan backend as well as HIP (how #150 was measured) gave the same 967 tok/s at 4096; the recipe
builds HIP only, as pwilkin's own installer does.

## Where server prefill goes

`bench/speed.py`, 16k prompt, ubatch 4096:

| | 32k context, 1 slot | 262k pool, 8 slots |
| --- | ---: | ---: |
| MTP off | 954 | 896 |
| MTP on | 837 | 824 |

Without MTP and at a small context the server matches `llama-bench`. The MTP draft head processes the prompt too,
which costs ~12% of prefill; the 262k pool costs ~1.5% more. Slot count (1 against 8) and `-b` above `-ub` made no
difference.

## Speculative decoding

`bench/speed.py`, one request, ubatch 4096, per-request decode tok/s (draft acceptance):

| Setting | Code | Prose |
| --- | ---: | ---: |
| MTP off | 27.9 | 25.2 |
| MTP draft 2 | 45.6 (0.82) | 40.6 (0.69) |
| **MTP draft 3** | **48.1 (0.77)** | **40.6 (0.61)** |
| MTP draft 4 | 41.9 (0.68) | 33.9 (0.50) |
| MTP draft 5 | 39.0 (0.57) | 30.8 (0.39) |
| draft 3 + `ngram-mod` | 48.5 (0.58) | 37.2 (0.45) |
| draft 3 + `--spec-draft-mtp-vocab 32768` | 48.2 (0.77) | 40.7 (0.61) |

MTP nearly doubles decode. Draft 3 is best, as Agention measured for this head; longer drafts lose to falling
acceptance. `ngram-mod` costs prose 8% and gains nothing on code. The draft-vocabulary limit has no effect on this
model: it applies to `qwen35` graphs only.

## Concurrency and `--spec-draft-max-slots` (#151)

ROCm 10.1 + PM4 at the final defaults, aggregate tok/s with N requests barrier-started together:

| Requests | Code, MTP always | max-slots 2 | max-slots 4 | Prose, MTP always | max-slots 2 | max-slots 4 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | 45.7 | 44.5 | 43.4 | 41.9 | 41.9 | 41.9 |
| 4 | 75.8 | 59.1 | 74.1 | 55.4 | 54.3 | 57.5 |
| 8 | 74.3 | 73.0 | 73.2 | 72.7 | 60.9 | 61.4 |

With this MTP head, drafting still pays at 8 concurrent requests (prose loses 16% without it), so the recipe does
not set `--spec-draft-max-slots`.

## Load mode

Five Vulkan loads in a row with `--load-mode none` (three) and `dio` (two), each followed by a speed run, all
loaded at 93.0 GiB GTT with no `BO_VA` errors. With `--load-mode mmap`, the second load of a boot failed
(`Couldn't update BO_VA (-12)`) and wedged the driver. On ROCm, `mmap` makes KFD refuse the mapping outright.
