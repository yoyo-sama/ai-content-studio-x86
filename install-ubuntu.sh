#!/usr/bin/env bash
# install-ubuntu.sh — installation/mise à jour idempotente de la stack AI Content
# Studio (nginx web, ComfyUI officiel, Ollama) sur Ubuntu 24.04 x86_64 + GPU Nvidia
# dédié. Pour Omarchy (Arch-based), utilisez install-omarchy.sh à la place — la
# logique applicative est partagée via scripts/lib-install-common.sh.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"
COMPOSE="docker compose"

# shellcheck source=scripts/lib-install-common.sh
source "$REPO_ROOT/scripts/lib-install-common.sh"

# ---------------------------------------------------------------------------
section "1/5 Vérifications d'environnement (Ubuntu 24.04 x86_64)"
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
  echo "  Installation officielle Docker pour Ubuntu (dépôt apt Docker) :"
  echo "    curl -fsSL https://get.docker.com | sudo sh"
  echo "  (ou suivez https://docs.docker.com/engine/install/ubuntu/ pour une install manuelle par paquets)"
  echo "  Ce script n'installe pas Docker automatiquement — relancez-le une fois Docker installé."
  exit 1
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
  warn "'nvidia-smi' introuvable — driver Nvidia propriétaire probablement absent ou non chargé."
  echo "  Installez-le via : sudo ubuntu-drivers autoinstall   (puis redémarrez)"
fi

if ! dpkg -l nvidia-container-toolkit >/dev/null 2>&1; then
  warn "paquet 'nvidia-container-toolkit' non détecté via dpkg."
  echo "  Installation (dépôt officiel Nvidia) :"
  echo "    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
  echo "    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \\"
  echo "      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \\"
  echo "      sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
  echo "    sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit"
  echo "    sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
fi

check_docker_common

run_install
