# Official ComfyUI (comfyanonymous/ComfyUI) for a dedicated x86_64 Nvidia GPU.
# Replaces the mmartial/comfyui-nvidia-docker image (GB10/DGX Spark specific, ARM64).
# No custom nodes (project rule, see AGENTS.md): vanilla ComfyUI only, with the single
# exception of comfy_kitchen (https://github.com/Comfy-Org/comfy-kitchen) — an official
# Comfy-Org package (not a third-party custom node) providing the ModelAttentionBackend
# node required by every workflows/api/*.json template in this project. Installed here from
# the official prebuilt PyPI wheel — the source repo (dellaicontent) compiled it for
# arm64/GB10 through a separate userscript; it is not an ARM-only package, only an image
# whose original userscript was arm64-only.
FROM nvidia/cuda:12.6.1-runtime-ubuntu24.04

ARG COMFYUI_REF=master
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      git python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /comfyui
RUN git clone --depth 1 --branch ${COMFYUI_REF} https://github.com/comfyanonymous/ComfyUI.git .

RUN pip3 install --break-system-packages --no-cache-dir \
      --extra-index-url https://download.pytorch.org/whl/cu124 \
      torch==2.6.0 torchvision==0.21.0 torchaudio==2.6.0 \
    && pip3 install --break-system-packages --no-cache-dir -r requirements.txt

# comfy_kitchen: official manylinux wheel published on PyPI, CUDA kernels statically
# linked — it talks to torch tensors through raw pointers (nanobind), not through libtorch's
# C++ ABI. No dependency on the installed torch version or on the system CUDA toolkit:
# a plain pip install, no build, no nvcc.
RUN pip3 install --break-system-packages --no-cache-dir comfy_kitchen

# Models, user settings and outputs are mounted as external volumes (see the ComfyUI stack
# in docker/stacks/comfyui.yml) — standard ComfyUI layout, no basedir/userscripts_dir.
VOLUME ["/comfyui/models", "/comfyui/user", "/comfyui/output", "/comfyui/input"]

EXPOSE 8188
CMD ["python3", "main.py", "--listen", "0.0.0.0", "--port", "8188"]
