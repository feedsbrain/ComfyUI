#!/bin/bash

# Fetch latest changes from upstream and rebase personal customizations on top
git fetch origin
git rebase origin/master

# Activate the Python virtual environment
source venv/bin/activate

# Install PyTorch, torchvision, and torchaudio with ROCm 7.1 support
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm7.1

# Install core ComfyUI Python dependencies
pip install -r requirements.txt

# Pull latest changes for all custom nodes
find custom_nodes -mindepth 1 -maxdepth 1 -type d -exec sh -c 'git -C "$0" pull' {} \;

# Install dependencies for all custom nodes
find custom_nodes -mindepth 1 -maxdepth 2 -type f -name 'requirements.txt' -exec sh -c 'pip install -r "$0"' {} \;

# onnxruntime-rocm only (no CUDA variant — system uses AMD/ROCm)
pip uninstall -y onnxruntime onnxruntime-gpu 2>/dev/null || true
pip install onnxruntime-rocm==1.22.2.post1 "numpy>=2.3.0,<3"

# onnxruntime-rocm ships with an executable stack flag that newer kernels reject;
# clear it so the .so loads without "cannot enable executable stack" errors
python3 - <<'PYEOF'
import struct, os
so = os.path.join(os.path.dirname(os.path.abspath(__file__)),
    "venv/lib/python3.12/site-packages/onnxruntime/capi/onnxruntime_pybind11_state.so")
if not os.path.exists(so):
    raise SystemExit(f"Not found: {so}")
PT_GNU_STACK = 0x6474e551
with open(so, "r+b") as f:
    data = bytearray(f.read())
e_phoff     = struct.unpack_from("<Q", data, 32)[0]
e_phentsize = struct.unpack_from("<H", data, 54)[0]
e_phnum     = struct.unpack_from("<H", data, 56)[0]
for i in range(e_phnum):
    base = e_phoff + i * e_phentsize
    if struct.unpack_from("<I", data, base)[0] == PT_GNU_STACK:
        flags = struct.unpack_from("<I", data, base + 4)[0]
        if flags & 0x1:
            struct.pack_into("<I", data, base + 4, flags & ~0x1)
            with open(so, "wb") as f:
                f.write(data)
            print("onnxruntime: cleared execstack flag")
        break
PYEOF

# Clear and purge pip cache to free up disk space
pip cache purge

# Deactivate the virtual environment
deactivate

# Push rebased branch (upstream changes + personal customizations) to personal remote
git push custom master --force-with-lease
