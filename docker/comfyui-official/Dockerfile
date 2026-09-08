# ComfyUI officiel (comfyanonymous/ComfyUI) pour GPU Nvidia dédié x86_64.
# Remplace l'image mmartial/comfyui-nvidia-docker (spécifique GB10/DGX Spark, ARM64).
# Pas de custom nodes (règle du projet, cf AGENTS.md) : ComfyUI vanilla uniquement,
# à l'exception de comfy_kitchen (https://github.com/Comfy-Org/comfy-kitchen) — un
# paquet officiel Comfy-Org (pas un custom node tiers) qui fournit le node
# ModelAttentionBackend requis par tous les templates workflows/api/*.json de ce
# projet. Installé ici via la roue PyPI officielle précompilée — le repo source
# (dellaicontent) le compilait pour arm64/GB10 via un userscript séparé ; ce n'est
# pas un paquet ARM-only, juste une image dont le userscript d'origine était
# arm64-only.
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

# comfy_kitchen : roue manylinux officielle publiée sur PyPI, noyaux CUDA liés
# statiquement — elle parle aux tensors torch via des pointeurs bruts (nanobind),
# pas via l'ABI C++ de libtorch. Aucune dépendance à la version de torch installée
# ni au toolkit CUDA système : simple install pip, pas de build, pas de nvcc.
RUN pip3 install --break-system-packages --no-cache-dir comfy_kitchen

# Modèles, réglages utilisateur et sorties montés en volumes externes (voir
# docker-compose.yml) — structure standard ComfyUI, pas de basedir/userscripts_dir.
VOLUME ["/comfyui/models", "/comfyui/user", "/comfyui/output", "/comfyui/input"]

EXPOSE 8188
CMD ["python3", "main.py", "--listen", "0.0.0.0", "--port", "8188"]
