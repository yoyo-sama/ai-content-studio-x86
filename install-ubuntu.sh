#!/usr/bin/env bash
# install-ubuntu.sh - safe installation, repair, update, diagnosis, and uninstall
# for AI Content Studio on Ubuntu 24.04/26.04 LTS, x86_64, with an NVIDIA GPU.
#
# The script deliberately does not install system packages or use sudo on the user's
# behalf. It prepares and verifies Docker-based application services, preserves model
# data, and refuses ambiguous ownership or destructive operations.
#
# ComfyUI is provided by the mmartial/ComfyUI-Nvidia-Docker image, which packages
# the Comfy-Org application with the CUDA/NVIDIA runtime. It is not an official
# Comfy-Org image. The image can be overridden with COMFY_IMAGE.

set -uo pipefail

SCRIPT_NAME="${0##*/}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT" || exit 1

COMPOSE="docker compose"
COMFY_DIR="${COMFY_DIR:-$HOME/comfyui-spark}"
OLLAMA_DIR="${OLLAMA_DIR:-$HOME/ollama}"
COMFY_IMAGE="${COMFY_IMAGE:-mmartial/comfyui-nvidia-docker:ubuntu24_cuda13.1-latest}"
# This is the x86_64 image variant; the DGX Spark ARM64 tag must not be used here.
OLLAMA_IMAGE="${OLLAMA_IMAGE:-ollama/ollama:latest}"
OLLAMA_MODEL="${OLLAMA_MODEL:-gemma4:e4b}"
WEB_PORT="${WEB_PORT:-8090}"
COMFY_PORT="${COMFY_PORT:-8188}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
MODELS_FILE="$REPO_ROOT/scripts/models.txt"
LEGACY_MODELS_DIR="$REPO_ROOT/comfyui/basedir/models"
OWNER_MARKER=".ai-content-studio-managed"
LOG_FILE="$HOME/install-ubuntu-$(date +%F-%H%M).log"

MODE=auto
MODE_ARG=""
SKIP_MODELS=0
ASSUME_YES=0
SMOKE=0
PURGE_DATA=0
ADOPT_COMFY=0
ADOPT_OLLAMA=0
UPDATE_COMFY_SOURCE=0
COMPONENTS=""

BOLD=""
RESET=""
[ -t 1 ] && { BOLD=$'\033[1m'; RESET=$'\033[0m'; }

section() { printf '\n%s=== %s ===%s\n' "$BOLD" "$*" "$RESET"; }
info() { printf '%s\n' "$*"; }
ok() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
acting() { case "$MODE" in fresh|repair|uninstall) return 0 ;; *) return 1 ;; esac; }
interactive() { [ -t 0 ] || [ -n "${INSTALL_UBUNTU_ASSUME_TTY:-}" ]; }

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME [options]

Modes:
  --check                         Diagnose only; do not change the system.
  --dry-run                      Print the plan; do not change the system.
  --mode fresh|repair|uninstall  Select the operation explicitly.

Installation and repair options:
  --skip-models                  Do not download models; existing models are still preserved.
  --update-comfy-source         Ask the ComfyUI image to refresh its persistent source/venv.
  --adopt-comfy                 Explicitly adopt a matching existing ComfyUI stack.
  --adopt-ollama                Explicitly adopt a matching existing Ollama stack.
  --smoke                       Run a reduced real ComfyUI render after verification.
  --yes                         Do not ask for confirmation.

Uninstall options:
  --components LIST              Comma-separated: web,updater,comfyui,ollama.
  --purge-data                  Also remove managed stack data; never enabled implicitly.

Other options:
  --log FILE                    Append the execution log to FILE.
  -h, --help                   Show this help.

Examples:
  $SCRIPT_NAME --check
  $SCRIPT_NAME --mode repair --yes --smoke
  $SCRIPT_NAME --mode repair --adopt-comfy --adopt-ollama --yes
  $SCRIPT_NAME --mode uninstall --components web,updater
  $SCRIPT_NAME --mode uninstall --components comfyui,ollama --purge-data

The script targets Ubuntu 24.04/26.04 LTS x86_64 with Docker Engine, Docker Compose v2,
NVIDIA drivers, and NVIDIA Container Toolkit already installed. It never installs system packages.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) MODE=check ;;
    --dry-run) MODE=dry-run ;;
    --mode)
      shift
      case "${1:-}" in
        fresh|repair|uninstall) MODE_ARG="$1"; [ "$MODE" = auto ] && MODE="$1" ;;
        *) err "unknown mode: ${1:-}"; usage; exit 1 ;;
      esac
      ;;
    --skip-models) SKIP_MODELS=1 ;;
    --update-comfy-source) UPDATE_COMFY_SOURCE=1 ;;
    --adopt-comfy) ADOPT_COMFY=1 ;;
    --adopt-ollama) ADOPT_OLLAMA=1 ;;
    --smoke) SMOKE=1 ;;
    --yes) ASSUME_YES=1 ;;
    --purge-data) PURGE_DATA=1 ;;
    --components) shift; COMPONENTS="${1:-}" ;;
    --log) shift; LOG_FILE="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

# Check and dry-run are read-only, including with respect to the log file.
if [ "$MODE" != check ] && [ "$MODE" != dry-run ]; then
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

confirm() {
  local answer
  printf '%s\n' "$1"
  interactive || { info "  no TTY: answered no"; return 1; }
  read -r answer || answer=""
  case "$answer" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "required command not found: $1"; return 1; }
}

health() {
  curl -fsS -m 10 "http://127.0.0.1:$1$2" >/dev/null 2>&1
}

wait_health() {
  local port="$1" path="$2" tries="$3" delay="$4" i
  for i in $(seq 1 "$tries"); do
    health "$port" "$path" && return 0
    sleep "$delay"
  done
  health "$port" "$path"
}

port_busy() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH "sport = :$1" 2>/dev/null | grep -q .
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && exec 3>&-
  fi
}

container_on_port() {
  docker ps --filter "publish=$1" --format '{{.Names}}' 2>/dev/null | head -n1
}

compose_label() {
  [ -n "${1:-}" ] || return 0
  docker inspect -f "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || true
}

container_image() {
  docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null || true
}

container_config() {
  compose_label "$1" com.docker.compose.project.config_files
}

path_equal() {
  local a b
  a="$(readlink -f "$1" 2>/dev/null || printf '%s' "$1")"
  b="$(readlink -f "$2" 2>/dev/null || printf '%s' "$2")"
  [ "$a" = "$b" ]
}

stack_marker() { [ -f "$1/$OWNER_MARKER" ]; }

managed_config() {
  local config="$1" dir="$2"
  [ -n "$config" ] || return 1
  if path_equal "$config" "$REPO_ROOT/docker-compose.yml"; then return 0; fi
  if path_equal "$config" "$dir/compose.yaml" && stack_marker "$dir"; then return 0; fi
  return 1
}

stopped_owned_container() {
  local role="$1" dir="$2" pattern c state cfg
  case "$role" in
    comfyui) pattern="mmartial/comfyui-nvidia-docker" ;;
    ollama) pattern="ollama/ollama" ;;
    *) return 1 ;;
  esac
  for c in $(docker ps -aq 2>/dev/null); do
    state="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || true)"
    case "$state" in exited|created|paused) ;; *) continue ;; esac
    case "$(container_image "$c")" in *"$pattern"*) ;; *) continue ;; esac
    cfg="$(container_config "$c")"
    if managed_config "$cfg" "$dir"; then
      docker inspect -f '{{.Name}}' "$c" 2>/dev/null | sed 's#^/##'
      return 0
    fi
  done
  return 1
}

compose_service_for_container() {
  compose_label "$1" com.docker.compose.service
}

resolve_bind_source() {
  local container="$1" destination="$2"
  docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$destination\"}}{{.Source}}{{end}}{{end}}" "$container" 2>/dev/null || true
}

write_env_value() {
  local file="$1" key="$2" value="$3" tmp
  mkdir -p "$(dirname "$file")" || return 1
  tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
  if [ -f "$file" ]; then
    awk -v k="$key" -v v="$value" '
      BEGIN { done=0 }
      $0 ~ "^[[:space:]]*" k "=" {
        if (!done) { print k "=" v; done=1 }
        next
      }
      { print }
      END { if (!done) print k "=" v }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod --reference="$file" "$tmp" 2>/dev/null || true
  else
    printf '%s=%s\n' "$key" "$value" > "$tmp"
    chmod 600 "$tmp"
  fi
  mv "$tmp" "$file"
}

write_owner_marker() {
  local dir="$1"
  printf 'managed-by=ai-content-studio\nmanaged-on=%s\n' "$(date -Is)" > "$dir/$OWNER_MARKER"
}

write_comfy_compose() {
  local file="$1"
  cat > "$file" <<COMPOSE
# Generated by install-ubuntu.sh. Do not edit while the installer manages this stack.
services:
  comfyui:
    image: \${COMFY_IMAGE}
    pull_policy: always
    container_name: ai-content-studio-comfyui
    ports:
      - "127.0.0.1:$COMFY_PORT:8188"
    volumes:
      - ./userscripts_dir:/userscripts_dir
      - ./run:/comfy/mnt
      - ./basedir:/basedir
      - /etc/localtime:/etc/localtime:ro
    environment:
      WANTED_UID: "\${WANTED_UID}"
      WANTED_GID: "\${WANTED_GID}"
      BASE_DIRECTORY: /basedir
      USE_NEW_MANAGER: "true"
      ENABLE_MANAGER_LEGACY_UI: "true"
      SECURITY_LEVEL: "normal"
      COMFY_CMDLINE_EXTRA: "\${COMFY_CMDLINE_EXTRA:-}"
      NVIDIA_VISIBLE_DEVICES: all
      NVIDIA_DRIVER_CAPABILITIES: compute,utility
      USE_UV: "true"
      FORCE_REINSTALL: "\${FORCE_REINSTALL:-false}"
      CUDA_HOME: /usr/local/cuda
      HF_TOKEN: "\${HF_TOKEN:-}"
      HF_HUB_DISABLE_TELEMETRY: "true"
    ulimits:
      memlock: -1
      stack: 67108864
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu, compute, utility]
    restart: unless-stopped
COMPOSE
}

write_ollama_compose() {
  local file="$1"
  cat > "$file" <<COMPOSE
# Generated by install-ubuntu.sh. Do not edit while the installer manages this stack.
services:
  ollama:
    image: \${OLLAMA_IMAGE}
    pull_policy: always
    container_name: ai-content-studio-ollama
    ports:
      - "127.0.0.1:$OLLAMA_PORT:11434"
    volumes:
      - ./data:/root/.ollama
    environment:
      OLLAMA_HOST: 0.0.0.0:11434
      OLLAMA_KEEP_ALIVE: "\${OLLAMA_KEEP_ALIVE:-5m}"
      OLLAMA_NUM_PARALLEL: "\${OLLAMA_NUM_PARALLEL:-1}"
      OLLAMA_MAX_LOADED_MODELS: "\${OLLAMA_MAX_LOADED_MODELS:-1}"
      NVIDIA_VISIBLE_DEVICES: all
      NVIDIA_DRIVER_CAPABILITIES: compute,utility
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu, compute, utility]
    restart: unless-stopped
COMPOSE
}

prepare_comfy() {
  mkdir -p "$COMFY_DIR/basedir/models" "$COMFY_DIR/run" "$COMFY_DIR/userscripts_dir" || return 1
  write_env_value "$COMFY_DIR/.env" WANTED_UID "$(id -u)" || return 1
  write_env_value "$COMFY_DIR/.env" WANTED_GID "$(id -g)" || return 1
  write_env_value "$COMFY_DIR/.env" COMFY_IMAGE "$COMFY_IMAGE" || return 1
  local count=0 f
  for f in "$REPO_ROOT"/docker/userscripts/*; do
    [ -f "$f" ] || continue
    cp -f "$f" "$COMFY_DIR/userscripts_dir/" && chmod +x "$COMFY_DIR/userscripts_dir/$(basename "$f")" && count=$((count + 1))
  done
  info "  deployed $count ComfyUI userscript(s) before startup"
}

prepare_ollama() {
  mkdir -p "$OLLAMA_DIR/data" || return 1
  write_env_value "$OLLAMA_DIR/.env" OLLAMA_IMAGE "$OLLAMA_IMAGE" || return 1
}

ensure_stack_file() {
  local role="$1" dir="$2" file="$dir/compose.yaml"
  mkdir -p "$dir" || return 1
  if [ -e "$file" ] && ! stack_marker "$dir"; then
    return 2
  fi
  if [ ! -e "$file" ]; then
    case "$role" in
      comfyui) write_comfy_compose "$file" || return 1 ;;
      ollama) write_ollama_compose "$file" || return 1 ;;
      *) return 1 ;;
    esac
  fi
  write_owner_marker "$dir" || return 1
  return 0
}

compose_pull_up() {
  local dir="$1" service="$2" force_reinstall="$3" config="$dir/compose.yaml"
  [ -f "$config" ] || { err "missing Compose file: $config"; return 1; }
  ( cd "$dir" || exit 1
    $COMPOSE config -q || exit 1
    if [ "$force_reinstall" = 1 ]; then
      FORCE_REINSTALL=true $COMPOSE pull --policy always "$service" || exit 1
      FORCE_REINSTALL=true $COMPOSE up -d --force-recreate "$service" || exit 1
    else
      FORCE_REINSTALL=false $COMPOSE pull --policy always "$service" || exit 1
      FORCE_REINSTALL=false $COMPOSE up -d "$service" || exit 1
    fi
  )
}

create_or_update_owned_stack() {
  local role="$1" dir="$2" service="$3" force="$4" rc
  if [ "$role" = comfyui ]; then
    prepare_comfy || return 1
  else
    prepare_ollama || return 1
  fi
  ensure_stack_file "$role" "$dir"; rc=$?
  [ "$rc" -eq 0 ] || { [ "$rc" -eq 2 ] && err "$role stack exists but is not marked as managed: $dir"; return 1; }
  compose_pull_up "$dir" "$service" "$force"
}

resolve_models_dir() {
  local c="${1:-}" source
  MODELS_DIR="$COMFY_DIR/basedir/models"
  [ -n "$c" ] || c="$(container_on_port "$COMFY_PORT" || true)"
  [ -n "$c" ] || return 0
  source="$(resolve_bind_source "$c" /basedir)"
  [ -n "$source" ] && MODELS_DIR="$source/models"
}

migrate_legacy_ollama_data() {
  local target="$OLLAMA_DIR/data"
  docker volume inspect ollama-data >/dev/null 2>&1 || return 0
  if ! acting; then
    info "  would copy legacy Docker volume ollama-data into $target"
    return 0
  fi
  mkdir -p "$target" || return 1
  info "copying legacy Ollama data into $target"
  docker run --rm -v ollama-data:/from -v "$target":/to alpine sh -c 'cp -a /from/. /to/'
}

validate_adoption_file() {
  local role="$1" file="$2"
  [ -f "$file" ] || return 1
  case "$role" in
    comfyui)
      grep -q 'mmartial/comfyui-nvidia-docker' "$file" 2>/dev/null || return 1
      grep -q 'BASE_DIRECTORY:[[:space:]]*/basedir' "$file" 2>/dev/null || return 1
      ;;
    ollama)
      grep -q 'ollama/ollama' "$file" 2>/dev/null || return 1
      grep -q '/root/.ollama' "$file" 2>/dev/null || return 1
      ;;
    *) return 1 ;;
  esac
}

safe_model_path() {
  local dir="$1" file="$2" path
  case "$dir/$file" in
    /*|*"/../"*|../*|*/..|*"//"*) return 1 ;;
  esac
  path="$MODELS_DIR/$dir/$file"
  case "$path" in "$MODELS_DIR"/*) return 0 ;; *) return 1 ;; esac
}

model_status() {
  local dir="$1" file="$2" wanted="$3" path have tolerance diff
  safe_model_path "$dir" "$file" || { printf 'INVALID\n'; return; }
  path="$MODELS_DIR/$dir/$file"
  [ -f "$path" ] || { printf 'MISSING\n'; return; }
  is_uint "$wanted" || { printf 'OK\n'; return; }
  have="$(stat -c '%s' "$path" 2>/dev/null || echo 0)"
  [ "$have" -gt 0 ] || { printf 'MISSING\n'; return; }
  diff=$((have - wanted)); [ "$diff" -lt 0 ] && diff=$((-diff))
  tolerance=$((wanted / 100)); [ "$tolerance" -lt 1 ] && tolerance=1
  [ "$diff" -le "$tolerance" ] && printf 'OK\n' || printf 'INCOMPLETE\n'
}

scan_models() {
  MODELS_OK=0; MODELS_BAD=0; MODELS_BYTES=0
  [ -f "$MODELS_FILE" ] || return 0
  local dir file size url status
  while IFS='|' read -r dir file size url; do
    case "${dir:-}" in ''|\#*) continue ;; esac
    status="$(model_status "$dir" "$file" "$size")"
    if [ "$status" = OK ]; then
      MODELS_OK=$((MODELS_OK + 1))
    else
      MODELS_BAD=$((MODELS_BAD + 1))
      is_uint "$size" && MODELS_BYTES=$((MODELS_BYTES + size))
    fi
  done < "$MODELS_FILE"
}

migrate_legacy_models() {
  local legacy="$LEGACY_MODELS_DIR" source rel target moved=0 left=0
  [ -d "$legacy" ] || return 0
  [ "$legacy" != "$MODELS_DIR" ] || return 0
  if ! acting; then
    info "  would migrate legacy models from $legacy to $MODELS_DIR"
    return 0
  fi
  mkdir -p "$MODELS_DIR" || { warn "cannot create model destination: $MODELS_DIR"; return 1; }
  while IFS= read -r -d '' source; do
    rel="${source#"$legacy"/}"
    target="$MODELS_DIR/$rel"
    mkdir -p "$(dirname "$target")" 2>/dev/null || { left=$((left + 1)); continue; }
    if [ -e "$target" ]; then
      left=$((left + 1)); continue
    fi
    if mv -n "$source" "$target" 2>/dev/null && [ ! -e "$source" ]; then
      moved=$((moved + 1))
    else
      left=$((left + 1))
    fi
  done < <(find "$legacy" -type f -print0 2>/dev/null)
  [ "$moved" -gt 0 ] || [ "$left" -gt 0 ] || return 0
  info "legacy model migration: moved=$moved left_behind=$left"
  if [ "$left" -gt 0 ]; then
    warn "some legacy model files were not moved; existing destination files were preserved"
    info "  if permissions are the cause: sudo chown -R $(id -u):$(id -g) \"$REPO_ROOT/comfyui\""
  fi
}

hf_token_acquire() {
  [ -n "${HF_TOKEN:-}" ] && return 0
  [ -f "$HOME/.cache/huggingface/token" ] && { HF_TOKEN="$(head -n1 "$HOME/.cache/huggingface/token" | tr -d '[:space:]')"; export HF_TOKEN; return 0; }
  [ -f "$HOME/.config/ai-content-studio/hf_token" ] && { HF_TOKEN="$(head -n1 "$HOME/.config/ai-content-studio/hf_token" | tr -d '[:space:]')"; export HF_TOKEN; return 0; }
  if interactive; then
    printf 'Hugging Face token (hidden, Enter to skip): '
    read -rs HF_TOKEN || HF_TOKEN=""
    printf '\n'
    export HF_TOKEN
  fi
}

curl_download() {
  local url="$1" part="$2" token="${HF_TOKEN:-}"
  case "$url" in https://*) ;; *) warn "refusing non-HTTPS model URL: $url"; return 1 ;; esac
  if [ -n "$token" ] && [[ "$url" == *huggingface.co* ]]; then
    printf 'header = "Authorization: Bearer %s"\n' "$token" | \
      curl -fL --retry 3 --retry-delay 3 --connect-timeout 20 -C - -K - -o "$part" "$url"
  else
    curl -fL --retry 3 --retry-delay 3 --connect-timeout 20 -C - -o "$part" "$url"
  fi
}

download_models() {
  [ -f "$MODELS_FILE" ] || { warn "$MODELS_FILE not found"; return 0; }
  local dir file size url status target part have diff tolerance downloaded=0 failed=0
  while IFS='|' read -r dir file size url; do
    case "${dir:-}" in ''|\#*) continue ;; esac
    url="${url%$'\r'}"
    if [ -z "$url" ] || [ "$url" = NON_TROUVE ]; then
      info "MANUAL: $MODELS_DIR/$dir/$file"
      failed=$((failed + 1)); continue
    fi
    status="$(model_status "$dir" "$file" "$size")"
    [ "$status" = OK ] && { info "SKIP: $dir/$file (already present and size matches)"; continue; }
    safe_model_path "$dir" "$file" || { warn "invalid model path: $dir/$file"; failed=$((failed + 1)); continue; }
    target="$MODELS_DIR/$dir/$file"
    part="$target.part"
    mkdir -p "$(dirname "$target")" || { failed=$((failed + 1)); continue; }
    info "downloading: $dir/$file"
    if ! curl_download "$url" "$part"; then
      warn "download failed: $url"
      failed=$((failed + 1)); continue
    fi
    if is_uint "$size"; then
      have="$(stat -c '%s' "$part" 2>/dev/null || echo 0)"
      diff=$((have - size)); [ "$diff" -lt 0 ] && diff=$((-diff))
      tolerance=$((size / 100)); [ "$tolerance" -lt 1 ] && tolerance=1
      if [ "$have" -le 0 ] || [ "$diff" -gt "$tolerance" ]; then
        warn "downloaded file has an unexpected size; keeping $part for inspection"
        failed=$((failed + 1)); continue
      fi
    fi
    mv -f "$part" "$target" || { failed=$((failed + 1)); continue; }
    downloaded=$((downloaded + 1))
  done < "$MODELS_FILE"
  info "model downloads: downloaded=$downloaded failed=$failed"
  [ "$failed" -eq 0 ]
}

disk_guard() {
  scan_models
  [ "$MODELS_BYTES" -gt 0 ] || return 0
  local available needed margin
  available="$(df -Pk "$MODELS_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
  is_uint "$available" || return 0
  needed="$MODELS_BYTES"
  margin=$((needed / 10))
  [ "$available" -gt $((needed + margin)) ] || { warn "not enough free disk space for the missing models"; return 1; }
}

ensure_ollama_model() {
  health "$OLLAMA_PORT" /api/version || { warn "Ollama is unavailable"; return 1; }
  if curl -fsS -m 10 "http://127.0.0.1:$OLLAMA_PORT/api/tags" 2>/dev/null | grep -q "\"$OLLAMA_MODEL\""; then
    ok "$OLLAMA_MODEL is already present"; return 0
  fi
  info "pulling $OLLAMA_MODEL through the Ollama API"
  curl -fsS --connect-timeout 10 -X POST "http://127.0.0.1:$OLLAMA_PORT/api/pull" \
    -H 'Content-Type: application/json' -d "{\"model\":\"$OLLAMA_MODEL\"}" >/dev/null 2>&1 || true
  curl -fsS -m 10 "http://127.0.0.1:$OLLAMA_PORT/api/tags" 2>/dev/null | grep -q "\"$OLLAMA_MODEL\""
}

NATIVE_OLLAMA=0
native_ollama_present() {
  command -v ollama >/dev/null 2>&1 || return 1
  NATIVE_OLLAMA=1
  return 0
}

compose_container_for_service() {
  local config="$1" service="$2" c cfg svc state
  for c in $(docker ps -aq 2>/dev/null); do
    cfg="$(container_config "$c")"
    svc="$(compose_service_for_container "$c")"
    state="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || true)"
    [ "$state" = running ] || [ "$state" = exited ] || [ "$state" = created ] || [ "$state" = paused ] || continue
    path_equal "$cfg" "$config" && [ "$svc" = "$service" ] && { printf '%s
' "$c"; return 0; }
  done
  return 1
}

PLATFORM_OK=1
DOCKER_OK=0
GPU_OK=0
NVIDIA_CTK_OK=0
COMFY_STATE=""
OLLAMA_STATE=""
WEB_STATE=""
COMFY_RUN=""
COMFY_STOPPED=""
OLLAMA_RUN=""
OLLAMA_STOPPED=""
WEB_RUN=""
WEB_STOPPED=""
UPDATER_RUN=""
UPDATER_STOPPED=""
MODELS_DIR="$COMFY_DIR/basedir/models"
PROBLEMS=0
COMFY_READY=0

preflight() {
  section "Preflight: Ubuntu 24.04/26.04 LTS x86_64 / NVIDIA"

  local os_id="" os_version="" os_codename="" os_name=""
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    os_id="${ID:-}"
    os_version="${VERSION_ID:-}"
    os_codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    os_name="${PRETTY_NAME:-$os_id $os_version}"
  fi

  if [ "$(uname -m)" != x86_64 ]; then
    err "architecture is $(uname -m); this installer targets x86_64"
    PLATFORM_OK=0
  else
    ok "x86_64 architecture"
  fi

  if [ "$os_id" = ubuntu ] && { [ "$os_version" = 24.04 ] || [ "$os_version" = 26.04 ]; }; then
    ok "$os_name detected${os_codename:+ ($os_codename)}"
  else
    err "unsupported operating system: ${os_name:-unknown}; expected Ubuntu 24.04 or 26.04"
    PLATFORM_OK=0
  fi

  require_cmd curl || exit 1
  require_cmd awk || exit 1
  require_cmd find || exit 1
  require_cmd stat || exit 1
  require_cmd df || exit 1
  require_cmd sed || exit 1
  require_cmd grep || exit 1
  require_cmd mktemp || exit 1
  require_cmd python3 || warn "python3 is missing; --smoke will not be available"

  if ! command -v docker >/dev/null 2>&1; then
    err "Docker is not installed. Install Docker Engine from Docker's official Ubuntu repository:"
    info "  https://docs.docker.com/engine/install/ubuntu/"
    info "  Required packages: docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    exit 1
  fi
  docker compose version >/dev/null 2>&1 || {
    err "Docker Compose v2 is missing. Install docker-compose-plugin from Docker's repository."
    exit 1
  }
  docker info >/dev/null 2>&1 || {
    err "Docker daemon is unavailable or this user lacks permission to access it."
    info "  Check: sudo systemctl enable --now docker"
    info "  Then add the user to the docker group if appropriate: sudo usermod -aG docker \$USER"
    exit 1
  }
  DOCKER_OK=1
  ok "Docker Engine and Docker Compose v2 are available"

  if command -v snap >/dev/null 2>&1 && snap list docker >/dev/null 2>&1; then
    warn "Docker is installed from Snap; GPU passthrough is not supported by this installer with Snap Docker"
    info "  Use Docker Engine from Docker's official APT repository instead."
    PLATFORM_OK=0
  fi

  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    ok "NVIDIA driver is responding"
    GPU_OK=1
  else
    warn "nvidia-smi cannot query an NVIDIA GPU"
    info "  Install the recommended Ubuntu NVIDIA driver, reboot, and run this script again."
  fi

  if command -v nvidia-ctk >/dev/null 2>&1; then
    ok "NVIDIA Container Toolkit is available"
    NVIDIA_CTK_OK=1
  else
    warn "nvidia-ctk is not available"
    info "  Install nvidia-container-toolkit from NVIDIA's official APT repository."
    info "  Then run: sudo nvidia-ctk runtime configure --runtime=docker"
    info "  Finally run: sudo systemctl restart docker"
  fi

  [ -f "$MODELS_FILE" ] || warn "$MODELS_FILE is missing; model installation will be incomplete"

  if [ "$MODE" = check ] || [ "$MODE" = dry-run ]; then
    return 0
  fi
  [ "$(id -u)" -ne 0 ] || { err "do not run this installer as root"; exit 1; }
  [ "$PLATFORM_OK" = 1 ] || exit 1
  if [ "$MODE" != uninstall ]; then
    [ "$GPU_OK" = 1 ] || { err "an operational NVIDIA GPU is required for installation or repair"; exit 1; }
    [ "$NVIDIA_CTK_OK" = 1 ] || { err "NVIDIA Container Toolkit is required for GPU containers"; exit 1; }
  fi
}

fingerprint() {
  COMFY_RUN="$(container_on_port "$COMFY_PORT" || true)"
  COMFY_STOPPED="$(stopped_owned_container comfyui "$COMFY_DIR" || true)"
  OLLAMA_RUN="$(container_on_port "$OLLAMA_PORT" || true)"
  OLLAMA_STOPPED="$(stopped_owned_container ollama "$OLLAMA_DIR" || true)"
  WEB_RUN="$(container_on_port "$WEB_PORT" || true)"
  WEB_STOPPED="$(compose_container_for_service "$REPO_ROOT/docker-compose.yml" ai-content-studio || true)"
  UPDATER_RUN="$(compose_container_for_service "$REPO_ROOT/docker-compose.yml" updater || true)"
  if health "$COMFY_PORT" /system_stats; then COMFY_STATE="running"; elif [ -n "$COMFY_RUN" ]; then COMFY_STATE="container-not-ready"; elif [ -n "$COMFY_STOPPED" ]; then COMFY_STATE="stopped-owned"; elif port_busy "$COMFY_PORT"; then COMFY_STATE="port-busy"; else COMFY_STATE="absent"; fi
  if health "$OLLAMA_PORT" /api/version; then OLLAMA_STATE="running"; elif [ -n "$OLLAMA_RUN" ]; then OLLAMA_STATE="container-not-ready"; elif native_ollama_present; then OLLAMA_STATE="native-not-ready"; elif [ -n "$OLLAMA_STOPPED" ]; then OLLAMA_STATE="stopped-owned"; elif port_busy "$OLLAMA_PORT"; then OLLAMA_STATE="port-busy"; else OLLAMA_STATE="absent"; fi
  if health "$WEB_PORT" /; then WEB_STATE="running"; elif [ -n "$WEB_RUN" ]; then WEB_STATE="container-not-ready"; elif [ -n "$WEB_STOPPED" ]; then WEB_STATE="container-not-ready"; elif port_busy "$WEB_PORT"; then WEB_STATE="port-busy"; else WEB_STATE="absent"; fi
  resolve_models_dir "$COMFY_RUN"
  scan_models
}

print_diagnosis() {
  section "Diagnosis"
  info "  ComfyUI : $COMFY_STATE${COMFY_RUN:+ ($COMFY_RUN)}${COMFY_STOPPED:+ (stopped: $COMFY_STOPPED)}"
  info "  Ollama  : $OLLAMA_STATE${OLLAMA_RUN:+ ($OLLAMA_RUN)}${OLLAMA_STOPPED:+ (stopped: $OLLAMA_STOPPED)}"
  info "  Web     : $WEB_STATE${WEB_RUN:+ ($WEB_RUN)}${WEB_STOPPED:+ (stopped: $WEB_STOPPED)}"
  info "  Updater : ${UPDATER_RUN:-${UPDATER_STOPPED:-not detected}}"
  info "  Models  : $MODELS_OK present, $MODELS_BAD missing/incomplete"
  info "  Path    : $MODELS_DIR"
  if [ -d "$LEGACY_MODELS_DIR" ]; then
    info "  Legacy  : $(find "$LEGACY_MODELS_DIR" -type f 2>/dev/null | wc -l) file(s) in $LEGACY_MODELS_DIR"
  fi
  info "  Image   : $COMFY_IMAGE"
}

build_plan() {
  section "Plan"
  case "$MODE" in
    check) info "read-only diagnosis; no changes"; return ;;
    dry-run) info "simulation; no changes" ;;
  esac
  info "  ComfyUI action: $COMFY_STATE"
  info "  Ollama action : $OLLAMA_STATE"
  info "  Web action    : $WEB_STATE"
  info "  Models        : migration is preservation; downloads=$([ "$SKIP_MODELS" = 1 ] && echo no || echo yes)"
  info "  Updater       : build/start from the repository Compose project"
}

ensure_comfy() {
  local cfg c
  case "$COMFY_STATE" in
    running)
      cfg="$(container_config "$COMFY_RUN")"
      if path_equal "$cfg" "$REPO_ROOT/docker-compose.yml"; then
        warn "ComfyUI belongs to the legacy repository stack; migrating it to $COMFY_DIR"
        if ! acting; then info "  would remove $COMFY_RUN and create the dedicated ComfyUI stack"; return 0; fi
        docker rm -f "$COMFY_RUN" >/dev/null 2>&1 || return 1
        create_or_update_owned_stack comfyui "$COMFY_DIR" comfyui "$UPDATE_COMFY_SOURCE" || return 1
        wait_health "$COMFY_PORT" /system_stats 90 10 || return 1
      elif managed_config "$cfg" "$COMFY_DIR" && acting; then
        ok "ComfyUI is managed by this installation; pulling the selected image"
        compose_pull_up "$COMFY_DIR" comfyui "$UPDATE_COMFY_SOURCE" || return 1
        wait_health "$COMFY_PORT" /system_stats 90 10 || return 1
      else
        ok "ComfyUI is already answering on :$COMFY_PORT; reused without touching it"
      fi
      ;;
    stopped-owned)
      c="$(stopped_owned_container comfyui "$COMFY_DIR" || true)"
      cfg="$(container_config "$c")"
      if path_equal "$cfg" "$REPO_ROOT/docker-compose.yml"; then
        warn "stopped ComfyUI belongs to the legacy repository stack; migrating it"
        if ! acting; then info "  would remove $c and create the dedicated ComfyUI stack"; return 0; fi
        docker rm -f "$c" >/dev/null 2>&1 || return 1
        create_or_update_owned_stack comfyui "$COMFY_DIR" comfyui "$UPDATE_COMFY_SOURCE" || return 1
        wait_health "$COMFY_PORT" /system_stats 90 10 || return 1
      elif ! acting; then
        info "  would start owned container $c"
        return 0
      else
        docker start "$c" >/dev/null 2>&1 || { err "could not start $c"; return 1; }
        wait_health "$COMFY_PORT" /system_stats 90 10 || { err "ComfyUI container started but did not become healthy"; return 1; }
      fi
      ;;
    container-not-ready)
      err "a container occupies ComfyUI's port but does not answer; refusing to create a second instance"
      return 1 ;;
    port-busy)
      err "port $COMFY_PORT is occupied by a non-responsive process; refusing to create ComfyUI"
      return 1 ;;
    *)
      if [ -f "$COMFY_DIR/compose.yaml" ] && ! stack_marker "$COMFY_DIR"; then
        if [ "$ADOPT_COMFY" != 1 ] || ! validate_adoption_file comfyui "$COMFY_DIR/compose.yaml"; then
          err "$COMFY_DIR/compose.yaml is not a verified managed ComfyUI stack; review it and use --adopt-comfy only if it matches"
          return 1
        fi
        write_owner_marker "$COMFY_DIR" || return 1
      fi
      if ! acting; then info "  would create/update the ComfyUI stack in $COMFY_DIR"; return 0; fi
      create_or_update_owned_stack comfyui "$COMFY_DIR" comfyui "$UPDATE_COMFY_SOURCE" || return 1
      wait_health "$COMFY_PORT" /system_stats 90 10 || { err "ComfyUI did not become healthy"; return 1; }
      ;;
  esac
  COMFY_RUN="$(container_on_port "$COMFY_PORT" || true)"
  resolve_models_dir "$COMFY_RUN"
  COMFY_READY=1
}

ensure_ollama() {
  local cfg c
  case "$OLLAMA_STATE" in
    running)
      cfg="$(container_config "$OLLAMA_RUN")"
      if path_equal "$cfg" "$REPO_ROOT/docker-compose.yml"; then
        warn "Ollama belongs to the legacy repository stack; migrating it to $OLLAMA_DIR"
        if ! acting; then info "  would copy legacy data, remove $OLLAMA_RUN, and create the dedicated Ollama stack"; return 0; fi
        migrate_legacy_ollama_data || return 1
        docker rm -f "$OLLAMA_RUN" >/dev/null 2>&1 || return 1
        create_or_update_owned_stack ollama "$OLLAMA_DIR" ollama 0 || return 1
        wait_health "$OLLAMA_PORT" /api/version 30 2 || return 1
      elif managed_config "$cfg" "$OLLAMA_DIR" && acting; then
        ok "Ollama is managed by this installation; pulling the selected image"
        compose_pull_up "$OLLAMA_DIR" ollama 0 || return 1
        wait_health "$OLLAMA_PORT" /api/version 30 2 || return 1
      else
        ok "Ollama is already answering on :$OLLAMA_PORT; reused without touching it"
      fi
      ;;
    stopped-owned)
      c="$(stopped_owned_container ollama "$OLLAMA_DIR" || true)"
      cfg="$(container_config "$c")"
      if path_equal "$cfg" "$REPO_ROOT/docker-compose.yml"; then
        warn "stopped Ollama belongs to the legacy repository stack; migrating it"
        if ! acting; then info "  would copy legacy data, remove $c, and create the dedicated Ollama stack"; return 0; fi
        migrate_legacy_ollama_data || return 1
        docker rm -f "$c" >/dev/null 2>&1 || return 1
        create_or_update_owned_stack ollama "$OLLAMA_DIR" ollama 0 || return 1
        wait_health "$OLLAMA_PORT" /api/version 30 2 || return 1
      elif ! acting; then
        info "  would start owned container $c"
        return 0
      else
        docker start "$c" >/dev/null 2>&1 || { err "could not start $c"; return 1; }
        wait_health "$OLLAMA_PORT" /api/version 30 2 || { err "Ollama container started but did not become healthy"; return 1; }
      fi
      ;;
    native-not-ready)
      err "a native Ollama installation is present but not answering; refusing to create a competing container"
      info "  start it with: sudo systemctl enable --now ollama"
      return 1 ;;
    container-not-ready|port-busy)
      err "port $OLLAMA_PORT is occupied but Ollama is not healthy; refusing to create a second instance"
      return 1 ;;
    *)
      if [ -f "$OLLAMA_DIR/compose.yaml" ] && ! stack_marker "$OLLAMA_DIR"; then
        if [ "$ADOPT_OLLAMA" != 1 ] || ! validate_adoption_file ollama "$OLLAMA_DIR/compose.yaml"; then
          err "$OLLAMA_DIR/compose.yaml is not a verified managed Ollama stack; review it and use --adopt-ollama only if it matches"
          return 1
        fi
        write_owner_marker "$OLLAMA_DIR" || return 1
      fi
      if ! acting; then info "  would create/update the Ollama stack in $OLLAMA_DIR"; return 0; fi
      create_or_update_owned_stack ollama "$OLLAMA_DIR" ollama 0 || return 1
      wait_health "$OLLAMA_PORT" /api/version 30 2 || { err "Ollama did not become healthy"; return 1; }
      ;;
  esac
}

ensure_web_and_updater() {
  if [ "$WEB_STATE" = running ]; then
    if [ -n "$WEB_RUN" ] && ! path_equal "$(container_config "$WEB_RUN")" "$REPO_ROOT/docker-compose.yml"; then
      err "a foreign container is answering on :$WEB_PORT; refusing to attach the updater to it"
      return 1
    fi
    ok "web application is already answering on :$WEB_PORT"
  elif [ "$WEB_STATE" = port-busy ] || [ "$WEB_STATE" = container-not-ready ]; then
    err "port $WEB_PORT is occupied but the web application is not healthy"
    return 1
  elif ! acting; then
    info "  would build and start ai-content-studio and updater from $REPO_ROOT"
  else
    [ -f "$REPO_ROOT/docker-compose.yml" ] || { err "missing $REPO_ROOT/docker-compose.yml"; return 1; }
    write_env_value "$REPO_ROOT/.env" COMFY_LORAS_DIR "$MODELS_DIR/loras" || return 1
    ( cd "$REPO_ROOT" && $COMPOSE config -q && $COMPOSE up -d --build ai-content-studio updater ) || { err "web/updater Compose startup failed"; return 1; }
    wait_health "$WEB_PORT" / 60 2 || { err "web application did not become healthy"; return 1; }
  fi
  if acting && [ "$WEB_STATE" = running ]; then
    write_env_value "$REPO_ROOT/.env" COMFY_LORAS_DIR "$MODELS_DIR/loras" || return 1
    ( cd "$REPO_ROOT" && $COMPOSE up -d --build updater ) || { err "updater startup failed"; return 1; }
  fi
}

run_models() {
  resolve_models_dir "$COMFY_RUN"
  mkdir -p "$MODELS_DIR" || { err "cannot create $MODELS_DIR"; return 1; }
  migrate_legacy_models || true
  if [ "$COMFY_READY" != 1 ]; then
    warn "ComfyUI is not ready; model downloads are skipped"
    return 1
  fi
  scan_models
  if [ "$SKIP_MODELS" = 1 ]; then
    info "model downloads skipped by --skip-models"
    return 0
  fi
  [ "$MODELS_BAD" -eq 0 ] && { info "all listed ComfyUI models are already present"; return 0; }
  disk_guard || return 1
  hf_token_acquire
  download_models || return 1
}

verify() {
  section "Verification through nginx (browser path)"
  local bad=0 endpoint code i
  for endpoint in / /comfy/system_stats /ollama/api/version /update/status; do
    code=000
    for i in 1 2 3 4 5; do
      code="$(curl -sS -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1:$WEB_PORT$endpoint" 2>/dev/null || echo 000)"
      [ "$code" = 200 ] && break
      sleep 2
    done
    printf '  %-24s HTTP %s\n' "$endpoint" "$code"
    [ "$code" = 200 ] || bad=$((bad + 1))
  done
  scan_models
  info "  models: $MODELS_OK present, $MODELS_BAD missing/incomplete"
  [ "$MODELS_BAD" -eq 0 ] || bad=$((bad + 1))
  if [ "$SKIP_MODELS" = 0 ]; then
    curl -fsS -m 10 "http://127.0.0.1:$WEB_PORT/ollama/api/tags" 2>/dev/null | grep -q "\"$OLLAMA_MODEL\"" || { warn "$OLLAMA_MODEL is not visible through nginx"; bad=$((bad + 1)); }
  fi
  [ "$bad" -eq 0 ] || PROBLEMS=$((PROBLEMS + bad))
}

smoke_test() {
  [ "$SMOKE" = 1 ] || return 0
  section "Smoke test"
  require_cmd python3 || { warn "python3 is required for --smoke"; PROBLEMS=$((PROBLEMS + 1)); return; }
  [ -f "$REPO_ROOT/tools/validate.py" ] || { warn "tools/validate.py is missing"; PROBLEMS=$((PROBLEMS + 1)); return; }
  local workflow="$REPO_ROOT/workflows/api/krea2_t2i.json"
  [ -f "$workflow" ] || { warn "smoke workflow is missing: $workflow"; PROBLEMS=$((PROBLEMS + 1)); return; }
  if ! acting; then
    info "  would run a reduced real ComfyUI render"
    return
  fi
  if COMFY_BASEDIR="${MODELS_DIR%/models}" python3 "$REPO_ROOT/tools/validate.py" "$workflow" --reduce; then
    ok "reduced ComfyUI render succeeded"
  else
    err "reduced ComfyUI render failed"
    PROBLEMS=$((PROBLEMS + 1))
  fi
}

uninstall_run() {
  section "Uninstall"
  [ "$PURGE_DATA" = 1 ] && info "data purge requested: only managed stack directories will be eligible"
  local want="web,updater,comfyui,ollama" name container cfg dir service
  [ -n "$COMPONENTS" ] && want="$COMPONENTS"
  if ! interactive && [ "$ASSUME_YES" != 1 ]; then err "uninstall requires a TTY or --yes"; return 1; fi
  for name in web updater comfyui ollama; do
    case ",$want," in *",$name,"*) ;; *) continue ;; esac
    container=""; cfg=""; dir=""; service=""
    case "$name" in
      comfyui) container="${COMFY_RUN:-$COMFY_STOPPED}"; dir="$COMFY_DIR"; service=comfyui ;;
      ollama) container="${OLLAMA_RUN:-$OLLAMA_STOPPED}"; dir="$OLLAMA_DIR"; service=ollama ;;
      web) container="${WEB_RUN:-$WEB_STOPPED}"; dir="$REPO_ROOT"; service=ai-content-studio ;;
      updater) container="${UPDATER_RUN:-$UPDATER_STOPPED}"; dir="$REPO_ROOT"; service=updater ;;
    esac
    [ -n "$container" ] || { info "$name: no running container detected"; continue; }
    cfg="$(container_config "$container")"
    if [ "$name" = web ] || [ "$name" = updater ]; then
      if ! path_equal "$cfg" "$REPO_ROOT/docker-compose.yml"; then
        warn "$name container is not managed by this repository; leaving it untouched"; continue
      fi
    elif ! managed_config "$cfg" "$dir"; then
      warn "$name container is not proven to be managed by this installer; leaving it untouched"; continue
    fi
    if [ "$ASSUME_YES" != 1 ] && ! confirm "Remove managed container $container ($name)? [y/N] "; then
      info "kept: $container"; continue
    fi
    if acting; then
      docker rm -f "$container" >/dev/null 2>&1 && ok "$container removed" || { warn "could not remove $container"; PROBLEMS=$((PROBLEMS + 1)); }
    else
      info "  would remove $container"
    fi
  done
  if [ "$PURGE_DATA" = 1 ]; then
    for dir in "$COMFY_DIR" "$OLLAMA_DIR"; do
      if stack_marker "$dir"; then
        if [ "$ASSUME_YES" = 1 ] || confirm "Remove managed data directory $dir? [y/N] "; then
          if acting; then rm -rf --one-file-system "$dir" && ok "removed $dir" || { warn "could not remove $dir"; PROBLEMS=$((PROBLEMS + 1)); }
          else info "  would remove $dir"; fi
        fi
      else
        warn "not purging unmarked directory: $dir"
      fi
    done
  fi
}

main() {
  [ "$MODE" = dry-run ] && info "DRY RUN: no system changes will be made"
  [ "$MODE" = check ] && info "CHECK: read-only diagnosis"
  preflight
  fingerprint
  print_diagnosis
  if [ "$MODE" = fresh ]; then
    if [ "$COMFY_STATE" != absent ] || [ "$OLLAMA_STATE" != absent ] || [ "$WEB_STATE" != absent ] || [ -d "$LEGACY_MODELS_DIR" ]; then
      err "--mode fresh requires a clean host; use --mode repair for an existing installation"
      exit 1
    fi
  fi
  [ "$MODE" = auto ] && { [ "$COMFY_STATE" = absent ] && [ "$OLLAMA_STATE" = absent ] && [ "$WEB_STATE" = absent ] && MODE=fresh || MODE=repair; }
  [ -n "$MODE_ARG" ] && MODE="$MODE_ARG"
  build_plan
  case "$MODE" in
    check) exit 0 ;;
    dry-run)
      if [ "$MODE_ARG" = uninstall ]; then uninstall_run; else info "no changes were made"; fi
      exit 0 ;;
    uninstall) uninstall_run; [ "$PROBLEMS" -eq 0 ] || exit 2; exit 0 ;;
    fresh|repair)
      if [ "$ASSUME_YES" != 1 ] && interactive; then confirm "Proceed with this plan? [y/N] " || { info "Nothing was changed."; exit 0; }; fi
      if ! ensure_comfy; then PROBLEMS=$((PROBLEMS + 1)); fi
      if ! ensure_ollama; then PROBLEMS=$((PROBLEMS + 1)); fi
      ensure_web_and_updater || PROBLEMS=$((PROBLEMS + 1))
      run_models || PROBLEMS=$((PROBLEMS + 1))
      if [ "$SKIP_MODELS" = 1 ]; then info "Ollama model pull skipped by --skip-models"; else ensure_ollama_model || PROBLEMS=$((PROBLEMS + 1)); fi
      verify
      smoke_test
      ;;
    *) err "unsupported mode: $MODE"; exit 1 ;;
  esac
  section "Summary"
  info "  repository: $REPO_ROOT"
  info "  ComfyUI models: $MODELS_DIR"
  info "  log: ${LOG_FILE:-not written in read-only mode}"
  if [ "$PROBLEMS" -eq 0 ]; then
    ok "the application passed the configured checks"
    exit 0
  fi
  err "$PROBLEMS problem(s) remain; the application is not proven functional"
  exit 2
}

main "$@"
