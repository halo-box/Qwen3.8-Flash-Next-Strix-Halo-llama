# Credits

This recipe is glue around other people's work. Where a file, setting or idea came from:

## Engine

- [halo-box/strix-llama.cpp](https://github.com/halo-box/strix-llama.cpp): the Strix Halo fork of llama.cpp this
  recipe serves with, pinned at `bed1b8a14`. It includes
  [#150](https://github.com/halo-box/strix-llama.cpp/pull/150) by [pwilkin](https://github.com/pwilkin) (HIP decode
  throughput for Qwen3.8-Flash-Next) and [#147](https://github.com/halo-box/strix-llama.cpp/pull/147) by
  [LaurentZuijdwijk](https://github.com/LaurentZuijdwijk) (`--spec-n-rs-seq`, capping the recurrent rollback
  snapshots MTP keeps per slot). [#151](https://github.com/halo-box/strix-llama.cpp/pull/151)
  (`--spec-draft-max-slots`) is merged at build time until it lands.
- [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) and [ggml](https://github.com/ggml-org/ggml), by
  Georgi Gerganov and the llama.cpp contributors (MIT). `qwen4exp` (Qwen3.8-Flash-Next) support is by Daniel Han
  ([#27742](https://github.com/ggml-org/llama.cpp/pull/27742)); the MTP graph by JJJYmmm
  ([#27739](https://github.com/ggml-org/llama.cpp/pull/27739)); `--kv-unified-per-slot` from
  [#24124](https://github.com/ggml-org/llama.cpp/pull/24124).

## Containers

- [kyuz0/amd-strix-halo-toolboxes](https://github.com/kyuz0/amd-strix-halo-toolboxes): `docker/Dockerfile.rocm` and
  `docker/Dockerfile.vulkan` are adapted from its `Dockerfile.rocm-10.0`, `Dockerfile.rocm-10.0-strix-llama` and
  `vulkan-radv` images (Fedora 44 base, TheRock Core SDK packages, the retained-PM4 runtime build and its gates,
  container device flags). `docker/patches/llama-grammar.patch` is copied from it. That repository carries no license
  file; ask its author before redistributing these parts.
- `docker/patches/llama-cpp-25992-rocm-host-buffer.patch`: kyuz0's packaging of the workaround for
  [llama.cpp #25992](https://github.com/ggml-org/llama.cpp/issues/25992), based on
  [PR #25863](https://github.com/ggml-org/llama.cpp/pull/25863) (MIT).
- [pwilkin/rocm-systems](https://github.com/pwilkin/rocm-systems) (`ilintar-experiments`): the retained-PM4 ROCr +
  HIP runtime in the `-pm4` images, built the way [pwilkin/strix-halo](https://github.com/pwilkin/strix-halo)'s
  `install.sh` does.
- [ROCm/TheRock](https://github.com/ROCm/TheRock): ROCm 10.0 and 10.1 for gfx1151, from AMD's package repository.

## Model

- [Qwen/Qwen3.8-Flash-Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next), by the Qwen team (Qwen Community
  License 1.0).
- [agentionai/Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-GGUF](https://huggingface.co/agentionai/Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-GGUF)
  (`v2/`) and [agentionai/Qwen3.8-Flash-Next-MTP-ROCmFP4-FAST-GGUF](https://huggingface.co/agentionai/Qwen3.8-Flash-Next-MTP-ROCmFP4-FAST-GGUF),
  quantized by [Agention](https://agention.ai). The q8_0 KV advice and the MTP draft-length measurements on their
  model cards are where this recipe's defaults started.
- The ROCmFP4 format: [charlie12345/ROCmFPX](https://github.com/charlie12345/ROCmFPX) and
  [ciru-ai/ROCmFPX](https://github.com/ciru-ai/ROCmFPX) (MIT).

## Settings and measurements

- [Nathanw1014/strix-halo-llamacpp](https://github.com/Nathanw1014/strix-halo-llamacpp): ubatch sizing, quantized KV
  at depth, and the Flash-Next load flags (`--load-mode mmap`, keeping the n-gram table off the GPU).
- kyuz0's [measured launch line](https://github.com/kyuz0/amd-strix-halo-toolboxes/blob/main/docs/building.md#retained-pm4-strix-halo-build-rocm-100-strix-llama)
  for `rocm-10.0-strix-llama` (`--lazy-mode on-direct`, never `GGML_CUDA_ENABLE_UNIFIED_MEMORY`), and his
  [AI Toolbox Cockpit](https://github.com/kyuz0/ai-toolbox-cockpit) profiles for the sibling Flash-Next forks.
- `bench/speed.py` reimplements the measurement method of MiaAI-Lab's `tools/bench.py` (prompt sizes, the code
  and prose decode tasks, medians, barrier-started concurrency, server-side timings); no code is copied.

## Structure

- [MiaAI-Lab](https://github.com/MiaAI-Lab) ([Mia's AI Lab](https://x.com/MiaAI_lab)), in particular
  [Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold):
  the shape of this repository and README — one `./start.sh` that prepares, checks, launches, waits and smoke-tests;
  `scripts/config.sh` with `.env` and environment overrides; measured performance and memory tables up front.
- [claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo](https://github.com/claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo):
  Strix Halo host preparation (GTT kernel parameters, `amd_iommu=off`, the `accelerator-performance` tuned
  profile, `--ipc=host`) and the rule that a `.env` file is data, never sourced.
