# ComfyUI officiel (comfyanonymous/ComfyUI) pour GPU Nvidia dédié x86_64.
# Remplace l'image mmartial/comfyui-nvidia-docker (spécifique GB10/DGX Spark, ARM64).
# Pas de custom nodes (règle du projet, cf AGENTS.md) : ComfyUI vanilla uniquement,
# à l'exception de comfy_kitchen (https://github.com/Comfy-Org/comfy-kitchen) — un
# paquet officiel Comfy-Org (pas un custom node tiers) qui fournit le node
# ModelAttentionBackend requis par tous les templates workflows/api/*.json de ce
# projet. Buildé ici pour x86_64/CUDA — le repo source (dellaicontent) le compilait
# pour arm64/GB10 via un userscript séparé ; ce n'est pas un paquet ARM-only, juste
# une image dont le userscript d'origine était arm64-only.
FROM nvidia/cuda:12.4.1-devel-ubuntu24.04

ARG COMFYUI_REF=master
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1

# devel (pas runtime) : comfy_kitchen se build depuis les sources et a besoin de nvcc.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git python3 python3-pip python3-dev build-essential ninja-build \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /comfyui
RUN git clone --depth 1 --branch ${COMFYUI_REF} https://github.com/comfyanonymous/ComfyUI.git .

RUN pip3 install --break-system-packages --no-cache-dir \
      --extra-index-url https://download.pytorch.org/whl/cu124 \
      torch torchvision torchaudio \
    && pip3 install --break-system-packages --no-cache-dir -r requirements.txt

# comfy_kitchen : build depuis git (pas de roue précompilée publiée). CXXFLAGS/CFLAGS
# forcés en C++20 — torch récent utilise des clauses `requires` (C++20) dans ses
# headers publics ; comfy_kitchen ne fixe pas lui-même son standard C++ et échoue à
# la compilation sans ce forçage (piège documenté dans le userscript d'origine).
RUN pip3 install --break-system-packages --no-cache-dir setuptools ninja nanobind \
    && CXXFLAGS="-std=c++20" CFLAGS="-std=c++20" MAX_JOBS="$(nproc)" \
       pip3 install --break-system-packages --no-cache-dir --no-build-isolation \
       "git+https://github.com/Comfy-Org/comfy-kitchen.git@main#egg=comfy_kitchen"

# Modèles, réglages utilisateur et sorties montés en volumes externes (voir
# docker-compose.yml) — structure standard ComfyUI, pas de basedir/userscripts_dir.
VOLUME ["/comfyui/models", "/comfyui/user", "/comfyui/output"]

EXPOSE 8188
CMD ["python3", "main.py", "--listen", "0.0.0.0", "--port", "8188"]
