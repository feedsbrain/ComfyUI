#!/bin/bash

source venv/bin/activate

# RX 6800 XT = gfx1030; ROCm 7.1 supports it natively — override kept for edge-case safety
export HSA_OVERRIDE_GFX_VERSION="10.3.0"

# SDMA causes hangs/illegal address on RDNA 2 under load
export HSA_ENABLE_SDMA=0

# AOTriton flash attention — production-stable on gfx1030 in ROCm 7.1
export TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1

# hipblaslt's pre-built Tensile library (TensileLibrary_lazy_gfx1030.dat) is missing from
# the PyTorch ROCm wheel for gfx1030 — fall back to hipblas which supports it correctly
export TORCH_BLAS_PREFER_HIPBLASLT=0

# MIOpen FAST mode (2): heuristic-only kernel selection — avoids minutes of exhaustive search at startup
export MIOPEN_FIND_MODE=2

# expandable_segments disabled (hipErrorIllegalAddress with GFX overrides).
# garbage_collection_threshold:0.3 — trigger GC early; gives headroom for ControlNet/MODEL_PATCH
# spikes on top of fp8 UNET + Qwen-3-4B encoder stack.
# max_split_size_mb:512 — 2048 was too coarse: the allocator held 2GB blocks it couldn't reuse,
# causing fragmentation under the Qwen-3-4B + fp8 UNET + ControlNet lite load at 768×1024.
# 512MB still covers all activation tensors at this resolution (latent 96×128) while allowing
# the pool to recycle freed blocks instead of growing indefinitely.
export PYTORCH_HIP_ALLOC_CONF=garbage_collection_threshold:0.3,max_split_size_mb:512

# glibc malloc: use mmap() for allocations >128MB so the OS can reclaim them immediately when freed.
# Without this, PyTorch's CPU tensors (offloaded model weights under --lowvram) stay in the brk heap
# and RSS grows across repeated runs until the process crashes from RAM exhaustion.
export MALLOC_MMAP_THRESHOLD_=134217728
export MALLOC_TRIM_THRESHOLD_=134217728

# WAN video generation: use VAEDecodeTiled (not VAEDecode) to avoid VRAM OOM on long sequences.
#   Only tested/working: WAN 2.2 5B model, 960×544 resolution, tile_size=256, overlap=64, temporal_size=16, temporal_overlap=4.

# proto-plus/protobuf C extension segfaults when google-generativeai is loaded by comfyui_starnodes;
# pure Python implementation avoids the crash at the cost of slightly slower protobuf serialization.
export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python

# Usage: ./webui.sh [any other ComfyUI args]
# --reserve-vram 2: keep 2 GB VRAM free. The Z-Image fp8 UNET (~3–4 GB) + Qwen-3-4B text
# encoder (~8 GB BF16) + ControlNet lite + ReActor + ESRGAN saturates the 16 GB RX 6800 XT;
# 2 GB headroom triggers model offloading before the allocator exhausts VRAM and dumps
# everything to RAM simultaneously.
# --use-split-cross-attention removed: it targets UNet cross-attention only and has no effect
# on Z-Image Turbo's DiT/transformer (Lumina2) architecture — it added overhead for nothing.
python main.py --enable-manager --reserve-vram 2 "$@"

deactivate
