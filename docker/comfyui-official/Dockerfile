# ComfyUI officiel (comfyanonymous/ComfyUI) pour GPU Nvidia dédié x86_64.
# Remplace l'image mmartial/comfyui-nvidia-docker (spécifique GB10/DGX Spark, ARM64).
# Pas de custom nodes (règle du projet, cf AGENTS.md) : ComfyUI vanilla uniquement.
FROM nvidia/cuda:12.4.1-runtime-ubuntu24.04

ARG COMFYUI_REF=master
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      git python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /comfyui
RUN git clone --depth 1 --branch ${COMFYUI_REF} https://github.com/comfyanonymous/ComfyUI.git .

# PyTorch via les roues précompilées CUDA 12.4 (elles embarquent leurs propres
# libs CUDA/cuDNN : pas besoin d'une image "devel", le runtime suffit).
RUN pip3 install --break-system-packages --no-cache-dir \
      --extra-index-url https://download.pytorch.org/whl/cu124 \
      torch torchvision torchaudio \
    && pip3 install --break-system-packages --no-cache-dir -r requirements.txt

# Modèles, réglages utilisateur et sorties montés en volumes externes (voir
# docker-compose.yml) — structure standard ComfyUI, pas de basedir/userscripts_dir.
VOLUME ["/comfyui/models", "/comfyui/user", "/comfyui/output"]

EXPOSE 8188
CMD ["python3", "main.py", "--listen", "0.0.0.0", "--port", "8188"]
