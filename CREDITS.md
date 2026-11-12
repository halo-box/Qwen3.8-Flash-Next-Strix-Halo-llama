# Credits

This recipe is glue around other people's work. Where a file, setting or idea came from:

## Engine

- [halo-box/strix-llama.cpp](https://github.com/halo-box/strix-llama.cpp): the Strix Halo fork of llama.cpp this
  recipe serves with, from its own `server-rocm` and `server-vulkan` images (built from upstream's `.devops/`
  Dockerfiles). It includes [#150](https://github.com/halo-box/strix-llama.cpp/pull/150) by
  [pwilkin](https://github.com/pwilkin) (HIP decode throughput for Qwen3.8-Flash-Next),
  [#147](https://github.com/halo-box/strix-llama.cpp/pull/147) by [LaurentZuijdwijk](https://github.com/LaurentZuijdwijk)
  (`--spec-n-rs-seq`), [#151](https://github.com/halo-box/strix-llama.cpp/pull/151) (`--spec-draft-max-slots`), and
  [#215](https://github.com/halo-box/strix-llama.cpp/pull/215) / [#216](https://github.com/halo-box/strix-llama.cpp/pull/216)
  (1M context and multi-slot compute memory for Flash-Next).
- [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) and [ggml](https://github.com/ggml-org/ggml), by
  Georgi Gerganov and the llama.cpp contributors (MIT). `qwen4exp` (Qwen3.8-Flash-Next) support is by Daniel Han
  ([#27742](https://github.com/ggml-org/llama.cpp/pull/27742)); the MTP graph by JJJYmmm
  ([#27739](https://github.com/ggml-org/llama.cpp/pull/27739)); `--kv-unified-per-slot` from
  [#24124](https://github.com/ggml-org/llama.cpp/pull/24124).
- Earlier versions of this recipe built their own images from Dockerfiles adapted from
  [kyuz0/amd-strix-halo-toolboxes](https://github.com/kyuz0/amd-strix-halo-toolboxes), with pwilkin's retained-PM4
  runtime. Two patches they carried go to strix-llama.cpp instead: the `flash_attn_mask_to_KV_max` bounds check for
  the last, partial tile of a prompt chunk (this repository's, found when a ~241k-token prompt faulted the GPU), and
  KYmidnight's `MAX_REPETITION_THRESHOLD` raise for large tool schemas
  ([kyuz0/amd-strix-halo-toolboxes#70](https://github.com/kyuz0/amd-strix-halo-toolboxes/issues/70)).

## Model

- [Qwen/Qwen3.8-Flash-Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next), by the Qwen team (Qwen Community
  License 1.0).
- [agentionai/Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-GGUF](https://huggingface.co/agentionai/Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-GGUF)
  (`v2/`) and [agentionai/Qwen3.8-Flash-Next-MTP-ROCmFP4-FAST-GGUF](https://huggingface.co/agentionai/Qwen3.8-Flash-Next-MTP-ROCmFP4-FAST-GGUF),
  quantized by [Agention](https://agention.ai). The q8_0 KV advice and the MTP draft-length measurements on their
  model cards are where this recipe's defaults started.
- The vision tower: `mmproj/mmproj-Qwen3.8-Flash-Next-f16.gguf` from the same Agention repository.
- The ROCmFP4 format: [charlie12345/ROCmFPX](https://github.com/charlie12345/ROCmFPX) and
  [ciru-ai/ROCmFPX](https://github.com/ciru-ai/ROCmFPX) (MIT).

## Settings and measurements

- [Nathanw1014/strix-halo-llamacpp](https://github.com/Nathanw1014/strix-halo-llamacpp): ubatch sizing, quantized KV
  at depth, and the Flash-Next load flags (`--load-mode mmap`, keeping the n-gram table off the GPU).
- kyuz0's [measured launch line](https://github.com/kyuz0/amd-strix-halo-toolboxes/blob/main/docs/building.md#retained-pm4-strix-halo-build-rocm-100-strix-llama)
  for `rocm-10.0-strix-llama` (`--lazy-mode on-direct`, never `GGML_CUDA_ENABLE_UNIFIED_MEMORY`), and his
  [AI Toolbox Cockpit](https://github.com/kyuz0/ai-toolbox-cockpit) profiles for the sibling Flash-Next forks.
- [MiaAI-Lab/sparkDash](https://github.com/MiaAI-Lab/sparkDash) (Apache 2.0): the Decode and Prefill benchmarks behind every
  speed figure. `bench/sparkdash.py` only drives its API; the prompts and the arithmetic are sparkDash's.

## Structure

- [MiaAI-Lab](https://github.com/MiaAI-Lab) ([Mia's AI Lab](https://x.com/MiaAI_lab)), in particular
  [Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold):
  the shape of this repository and README — one `./start.sh` that prepares, checks, launches, waits and smoke-tests;
  `scripts/config.sh` with `.env` and environment overrides; measured performance and memory tables up front.
- [claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo](https://github.com/claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo):
  `setup.sh` follows its setup.sh (host checks, the GTT kernel parameters `ttm.pages_limit=31457280
  amdgpu.gttsize=122880`, `amd_iommu=off`, the `accelerator-performance` tuned profile, one reboot at the end),
  plus `--ipc=host` and the rule that a `.env` file is data, never sourced.
