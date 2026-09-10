#!/usr/bin/env bash
# install-omarchy.sh — idempotent install/update of the AI Content Studio stack (nginx web,
# official ComfyUI, Ollama) on Omarchy (Arch Linux/Hyprland) x86_64 with a dedicated Nvidia
# GPU. For Ubuntu 24.04, use install-ubuntu.sh instead — the application logic is shared
# through scripts/lib-install-common.sh.
# Omarchy runs on Hyprland/Wayland but everything here is headless docker: the graphical
# environment has no bearing on this installation.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"
COMPOSE="docker compose"

# shellcheck source=scripts/lib-install-common.sh
source "$REPO_ROOT/scripts/lib-install-common.sh"

# ---------------------------------------------------------------------------
section "1/5 Environment checks (Omarchy / Arch Linux x86_64)"
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
  echo "  Install it with pacman (official Arch packages 'docker' and 'docker-compose'):"
  echo "    sudo pacman -S --needed docker docker-compose"
  echo "    sudo systemctl enable --now docker"
  echo "    sudo usermod -aG docker \$USER   # then log back in (or run 'newgrp docker')"
  echo "  This script does not install Docker for you — run it again once Docker is installed."
  exit 1
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
  warn "'nvidia-smi' not found — the proprietary Nvidia driver is probably missing."
  echo "  Install it (official Arch package, pick the one matching your kernel):"
  echo "    sudo pacman -S --needed nvidia nvidia-utils   # or nvidia-dkms on a non-standard kernel"
  echo "  Then reboot."
fi

if ! pacman -Qi nvidia-container-toolkit >/dev/null 2>&1; then
  warn "package 'nvidia-container-toolkit' not detected via pacman."
  echo "  It ships in Arch's 'extra' repository (otherwise from the AUR with yay):"
  echo "    sudo pacman -S --needed nvidia-container-toolkit"
  echo "    # if missing from 'extra' on your mirror: yay -S nvidia-container-toolkit"
  echo "    sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
fi

check_docker_common

run_install
