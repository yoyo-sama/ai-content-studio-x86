#!/usr/bin/env bash
# install-ubuntu.sh — idempotent install/update of the AI Content Studio stack (nginx web,
# official ComfyUI, Ollama) on Ubuntu 24.04 x86_64 with a dedicated Nvidia GPU. For Omarchy
# (Arch-based), use install-omarchy.sh instead — the application logic is shared through
# scripts/lib-install-common.sh.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"
COMPOSE="docker compose"

# shellcheck source=scripts/lib-install-common.sh
source "$REPO_ROOT/scripts/lib-install-common.sh"

# ---------------------------------------------------------------------------
section "1/5 Environment checks (Ubuntu 24.04 x86_64)"
# ---------------------------------------------------------------------------
ARCH="$(uname -m)"
if [ "$ARCH" != "x86_64" ]; then
  warn "detected architecture '$ARCH' (this script targets an x86_64 machine with a dedicated Nvidia GPU)."
  echo "  Continuing anyway (graceful degradation)."
else
  echo "OK: x86_64 architecture."
fi

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  warn "Docker (+ the 'docker compose' plugin) is missing or incomplete."
  echo "  Official Docker install for Ubuntu (Docker apt repository):"
  echo "    curl -fsSL https://get.docker.com | sudo sh"
  echo "  (or follow https://docs.docker.com/engine/install/ubuntu/ for a manual package install)"
  echo "  This script does not install Docker for you — run it again once Docker is installed."
  exit 1
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
  warn "'nvidia-smi' not found — the proprietary Nvidia driver is probably missing or not loaded."
  echo "  Install it with: sudo ubuntu-drivers autoinstall   (then reboot)"
fi

if ! dpkg -l nvidia-container-toolkit >/dev/null 2>&1; then
  warn "package 'nvidia-container-toolkit' not detected via dpkg."
  echo "  Install it (official Nvidia repository):"
  echo "    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
  echo "    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \\"
  echo "      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \\"
  echo "      sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
  echo "    sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit"
  echo "    sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
fi

check_docker_common

run_install
