#!/usr/bin/env bash
# install-omarchy.sh — installation/mise à jour idempotente de la stack AI Content
# Studio (nginx web, ComfyUI officiel, Ollama) sur Omarchy (Arch Linux/Hyprland)
# x86_64 + GPU Nvidia dédié. Pour Ubuntu 24.04, utilisez install-ubuntu.sh à la
# place — la logique applicative est partagée via scripts/lib-install-common.sh.
# Omarchy tourne sous Hyprland/Wayland mais tout ici est du docker headless :
# aucun impact de l'environnement graphique sur cette installation.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"
COMPOSE="docker compose"

# shellcheck source=scripts/lib-install-common.sh
source "$REPO_ROOT/scripts/lib-install-common.sh"

# ---------------------------------------------------------------------------
section "1/5 Vérifications d'environnement (Omarchy / Arch Linux x86_64)"
# ---------------------------------------------------------------------------
ARCH="$(uname -m)"
if [ "$ARCH" != "x86_64" ]; then
  warn "architecture détectée '$ARCH' (ce script cible un poste x86_64 avec GPU Nvidia dédié)."
  echo "  Le script continue quand même (dégradation propre)."
else
  echo "OK: architecture x86_64."
fi

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  warn "Docker (+ plugin 'docker compose') introuvable ou incomplet."
  echo "  Installation via pacman (paquets officiels Arch : 'docker' et 'docker-compose') :"
  echo "    sudo pacman -S --needed docker docker-compose"
  echo "    sudo systemctl enable --now docker"
  echo "    sudo usermod -aG docker \$USER   # puis se reconnecter (ou 'newgrp docker')"
  echo "  Ce script n'installe pas Docker automatiquement — relancez-le une fois Docker installé."
  exit 1
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
  warn "'nvidia-smi' introuvable — driver Nvidia propriétaire probablement absent."
  echo "  Installation (paquet officiel Arch, adapter au noyau utilisé) :"
  echo "    sudo pacman -S --needed nvidia nvidia-utils   # ou nvidia-dkms sur noyau non standard"
  echo "  Puis redémarrez."
fi

if ! pacman -Qi nvidia-container-toolkit >/dev/null 2>&1; then
  warn "paquet 'nvidia-container-toolkit' non détecté via pacman."
  echo "  Il est disponible dans le dépôt 'extra' d'Arch (sinon via l'AUR avec yay) :"
  echo "    sudo pacman -S --needed nvidia-container-toolkit"
  echo "    # si absent du dépôt 'extra' sur votre miroir : yay -S nvidia-container-toolkit"
  echo "    sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
fi

check_docker_common

run_install
