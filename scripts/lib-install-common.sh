#!/usr/bin/env bash
# lib-install-common.sh — logic shared by install-ubuntu.sh and install-omarchy.sh.
# Detects services by their actual role (HTTP health), not by container name; reuses
# everything already running — including an Ollama installed natively (systemd), which is
# not a container; never recreates or destroys a service it does not own.
# Only the system prerequisite checks (section 1/5) differ between distributions: they live
# in each calling script, not here.
#
# Deployed layout (one stack per service, at the root of the home directory):
#   ~/<repo>    app: nginx :8090 + updater
#   ~/comfyui   ComfyUI :8188  (template docker/stacks/comfyui.yml)
#   ~/ollama    Ollama :11434  (template docker/stacks/ollama.yml)
#
# Contract with the calling script: define REPO_ROOT and COMPOSE, then `source` this file
# and call check_docker_common() followed by run_install().

COMFY_DIR="$HOME/comfyui"
OLLAMA_DIR="$HOME/ollama"
COMFY_IMAGE="ai-content-studio-comfyui:local"
OLLAMA_MODEL="gemma4:e4b"

section() { printf '\n=== %s ===\n' "$*"; }
warn()    { printf 'WARNING: %s\n' "$*"; }

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Finds the container actually answering on a given port:
# 1) through the published port mapping (docker ps --filter publish=PORT)
# 2) otherwise, among network_mode: host containers, the one serving this repo through nginx
#    (the updater also mounts the repo root — the mount destination tells them apart).
find_container_by_port() {
  local port="$1" name c
  name=$(docker ps --filter "publish=${port}" --format '{{.Names}}' 2>/dev/null | head -n1)
  if [ -n "$name" ]; then
    printf '%s\n' "$name"
    return 0
  fi
  for c in $(docker ps --filter "network=host" --format '{{.Names}}' 2>/dev/null); do
    if docker inspect --format '{{json .Mounts}}' "$c" 2>/dev/null | grep -qF "\"Source\":\"${REPO_ROOT}\"" \
       && docker inspect --format '{{json .Mounts}}' "$c" 2>/dev/null | grep -qF '"Destination":"/usr/share/nginx/html"'; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

# Is the port held by any process at all (docker or not)?
port_busy() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH "sport = :$1" 2>/dev/null | grep -q .
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && exec 3>&-
  fi
}

# Refuses to create a stack when the port is already held by something other than the
# expected service: without this, docker fails with the opaque "port is already allocated".
port_taken_by_other() {   # $1=port  $2=readable service name
  port_busy "$1" || return 1
  warn "port $1 is in use but $2 does not answer its health check."
  echo "  Another process holds it — a native install that is stopped or broken, or another service."
  echo "  Free the port or start that service, then run this script again. Nothing was created."
  return 0
}

# Waits for a URL to answer. $1=url $2=number of attempts $3=delay between attempts (s).
wait_for_http() {
  local i
  for i in $(seq 1 "$2"); do
    curl -sf "$1" >/dev/null 2>&1 && return 0
    sleep "$3"
  done
  curl -sf "$1" >/dev/null 2>&1
}

# A service may be installed but STOPPED: its container exists, its port is free. Creating a
# second one would fail on a name clash (container names are unique) and, for Ollama, would
# leave two instances fighting over the same port. So we restart the existing one instead.
# Returns: 0 = started and healthy, 2 = started but silent, 1 = no matching stopped container.
RESTARTED_CONTAINER=""
restart_stopped_service() {   # $1=image pattern  $2=readable name  $3=health url  $4=attempts  $5=delay
  local c
  c="$(docker ps -a --filter status=exited --filter status=created --filter status=paused \
        --format '{{.Names}}\t{{.Image}}' 2>/dev/null | awk -F'\t' -v p="$1" 'index($2,p){print $1; exit}')"
  [ -n "$c" ] || return 1
  RESTARTED_CONTAINER="$c"
  echo "$2 found in a stopped container ('$c') — starting it instead of creating a second one."
  docker start "$c" >/dev/null 2>&1 || { warn "could not start container '$c'."; return 2; }
  if wait_for_http "$3" "$4" "$5"; then
    echo "OK: $2 answers."
    return 0
  fi
  warn "container '$c' was started but $2 still does not answer — see 'docker logs $c'."
  return 2
}

# Ollama installed natively (official installer + systemd) is not a container, and creating
# one while it is merely stopped would leave two instances fighting over port 11434. So we
# try to start the existing service instead.
NATIVE_OLLAMA_PRESENT=0
native_ollama_present() {
  command -v ollama >/dev/null 2>&1 && return 0
  command -v systemctl >/dev/null 2>&1 && systemctl cat ollama.service >/dev/null 2>&1
}
start_native_ollama() {
  native_ollama_present || return 1
  NATIVE_OLLAMA_PRESENT=1
  echo "Ollama is installed natively on this host but not answering — trying to start it."
  if [ "$(id -u)" = 0 ]; then
    systemctl start ollama >/dev/null 2>&1
  else
    # 'sudo -n' NEVER asks for a password: either passwordless sudo is already allowed, or
    # it fails immediately — an install script must never hang on a prompt.
    sudo -n systemctl start ollama >/dev/null 2>&1
  fi
  if wait_for_http "http://localhost:11434/api/version" 15 2; then
    echo "OK: native Ollama service started."
    return 0
  fi
  warn "could not start the native Ollama service automatically (no passwordless sudo?)."
  echo "  Start it yourself, then run this script again:"
  echo "    sudo systemctl enable --now ollama     # or, without systemd: ollama serve &"
  echo "  No Ollama container was created, to avoid two instances fighting over port 11434."
  return 1
}

# Actual model path of a ComfyUI container, read from its bind-mount (it overrides the
# default path: that is where this particular ComfyUI really reads its models).
resolve_comfy_paths() {   # $1=container
  local m
  m="$(docker inspect --format '{{ range .Mounts }}{{ if eq .Destination "/comfyui/models" }}{{ .Source }}{{ end }}{{ end }}' "$1" 2>/dev/null || true)"
  if [ -n "$m" ]; then
    COMFY_MODELS_DIR="$m"
    echo "Actual path detected: models=$COMFY_MODELS_DIR"
  else
    warn "/comfyui/models mount not found on this container — deploy models manually for it."
  fi
}

# The part of the environment check shared by both distros (docker, compose plugin, nvidia
# runtime). The caller handles the rest (its own distro's system packages).
check_docker_common() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: 'docker' not found in PATH. Install Docker before running this script again." >&2
    exit 1
  fi
  if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: the 'docker compose' (v2) plugin is missing. Install it before running this script again." >&2
    exit 1
  fi
  echo "OK: docker + docker compose available."

  if docker info >/dev/null 2>&1 && docker info 2>/dev/null | grep -qi 'nvidia'; then
    echo "OK: nvidia runtime detected by 'docker info'."
  elif command -v nvidia-smi >/dev/null 2>&1; then
    echo "OK: 'nvidia-smi' available (nvidia-container-toolkit likely installed)."
  else
    warn "cannot confirm nvidia-container-toolkit is installed. GPU services (ComfyUI/Ollama) may fail to start. Continuing."
  fi
}

build_comfy_image() {
  echo "Building the ComfyUI image ($COMFY_IMAGE) — first build takes several minutes."
  docker build -t "$COMFY_IMAGE" "$REPO_ROOT/docker/comfyui-official"
}

create_comfy_stack() {
  echo "Creating the ComfyUI stack in $COMFY_DIR."
  # Folders are created BEFORE the container: a bind-mount whose source does not exist yet
  # is created by dockerd as root:root — the folder is then locked for the user, and every
  # model download afterwards fails with "permission denied".
  mkdir -p "$COMFY_DIR/models" "$COMFY_DIR/user" "$COMFY_DIR/output" "$COMFY_DIR/input"
  [ -f "$COMFY_DIR/compose.yaml" ] || cp "$REPO_ROOT/docker/stacks/comfyui.yml" "$COMFY_DIR/compose.yaml"
  build_comfy_image || warn "ComfyUI image build failed — 'docker compose up' will fail if no local image exists."
  ( cd "$COMFY_DIR" && $COMPOSE up -d )
  COMFY_CREATED=1
  COMFY_CONTAINER="$(find_container_by_port 8188 || echo "comfyui-nvidia")"
  COMFY_MODELS_DIR="$COMFY_DIR/models"
}

create_ollama_stack() {
  echo "Creating the Ollama stack in $OLLAMA_DIR."
  mkdir -p "$OLLAMA_DIR/data"
  [ -f "$OLLAMA_DIR/compose.yaml" ] || cp "$REPO_ROOT/docker/stacks/ollama.yml" "$OLLAMA_DIR/compose.yaml"
  ( cd "$OLLAMA_DIR" && $COMPOSE up -d )
  OLLAMA_CONTAINER="$(find_container_by_port 11434 || echo "ollama-api")"
  # 'up -d' returns as soon as the container is started, not when the server is listening.
  # Without this wait, the model step below could conclude "Ollama unavailable" on a service
  # that simply had not finished booting.
  wait_for_http "http://localhost:11434/api/version" 15 2 \
    || warn "Ollama does not answer yet after 30 s — see 'docker logs $OLLAMA_CONTAINER'."
}

# Idempotent detection + (re)creation of the services, model downloads, Ollama model pull,
# final summary.
run_install() {
  # -------------------------------------------------------------------------
  section "2/5 Detecting services by actual role (HTTP health), not by name"
  # -------------------------------------------------------------------------
  COMFY_MODELS_DIR="$COMFY_DIR/models"
  COMFY_CONTAINER=""
  COMFY_STATUS=""
  COMFY_CREATED=0

  echo "--- ComfyUI (:8188) ---"
  if curl -sf http://localhost:8188/system_stats >/dev/null 2>&1; then
    COMFY_CONTAINER="$(find_container_by_port 8188 || true)"
    if [ -z "$COMFY_CONTAINER" ]; then
      warn "ComfyUI answers on :8188 but no matching container could be identified. Reusing the service as is, without container management."
      COMFY_STATUS="reused (container not identified)"
    else
      echo "ComfyUI already running in container '$COMFY_CONTAINER' — reusing it, no recreation."
      COMFY_STATUS="reused ($COMFY_CONTAINER)"

      IMAGE="$(docker inspect --format '{{.Config.Image}}' "$COMFY_CONTAINER" 2>/dev/null || true)"
      PROJECT="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$COMFY_CONTAINER" 2>/dev/null || true)"
      CONFIGFILE="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$COMFY_CONTAINER" 2>/dev/null || true)"

      if [ "$CONFIGFILE" = "$REPO_ROOT/docker-compose.yml" ]; then
        # Container created by the OLD layout (comfyui/ollama services inside the app's
        # compose file, volumes under $REPO_ROOT/comfyui). Replace it with the stack.
        warn "ComfyUI inherited from the old layout — migrating to $COMFY_DIR."
        docker rm -f "$COMFY_CONTAINER" >/dev/null 2>&1 || true
        if [ -d "$REPO_ROOT/comfyui/models" ]; then
          echo "  Old model folder left untouched: $REPO_ROOT/comfyui/models"
          echo "  Move its content to $COMFY_DIR/models to avoid downloading again."
        fi
        create_comfy_stack
        COMFY_STATUS="migrated to $COMFY_DIR ($COMFY_CONTAINER)"
      elif [ "$CONFIGFILE" = "$COMFY_DIR/compose.yaml" ]; then
        echo "Container managed by our own stack — rebuilding the image and recreating if it changed."
        build_comfy_image || warn "'docker build' failed — continuing with the existing local image."
        ( cd "$COMFY_DIR" && $COMPOSE up -d )
        NEW_NAME="$(find_container_by_port 8188 || true)"
        [ -n "$NEW_NAME" ] && COMFY_CONTAINER="$NEW_NAME"
        COMFY_STATUS="updated ($COMFY_CONTAINER)"
      else
        warn "ComfyUI container found but managed by ANOTHER compose project (project='${PROJECT:-none}', file='${CONFIGFILE:-none/not-compose}', image='${IMAGE:-unknown}')."
        echo "  No automatic update: we never touch a container we do not own."
      fi

      # Actual path from the container's effective bind-mount (useful even when the
      # container belongs to another compose project).
      resolve_comfy_paths "$COMFY_CONTAINER"
    fi
  else
    echo "No ComfyUI answering on :8188."
    restart_stopped_service "ai-content-studio-comfyui" "ComfyUI" "http://localhost:8188/system_stats" 60 10
    rc=$?
    if [ "$rc" -eq 0 ]; then
      COMFY_CONTAINER="$RESTARTED_CONTAINER"
      COMFY_STATUS="restarted ($COMFY_CONTAINER)"
      resolve_comfy_paths "$COMFY_CONTAINER"
    elif [ "$rc" -eq 2 ]; then
      COMFY_CONTAINER="$RESTARTED_CONTAINER"
      COMFY_STATUS="restarted but not answering ($COMFY_CONTAINER)"
      resolve_comfy_paths "$COMFY_CONTAINER"
    elif port_taken_by_other 8188 "ComfyUI"; then
      COMFY_STATUS="skipped (port 8188 busy)"
    else
      create_comfy_stack
      COMFY_STATUS="created ($COMFY_CONTAINER, stack $COMFY_DIR)"
    fi
  fi

  # --- Ollama (port 11434) : conteneur OU installation native (systemd) ---
  OLLAMA_CONTAINER=""
  OLLAMA_STATUS=""
  echo "--- Ollama (:11434) ---"
  if curl -sf http://localhost:11434/api/version >/dev/null 2>&1; then
    OLLAMA_CONTAINER="$(find_container_by_port 11434 || true)"
    if [ -z "$OLLAMA_CONTAINER" ]; then
      # Common case on Ubuntu/Omarchy: Ollama installed by the official script and served
      # by systemd. Not a container — we reuse it as is, and the model is pulled through
      # the HTTP API (step 4/5), not with 'docker exec'.
      OLLAMA_CONTAINER="native or unidentified service"
      echo "Ollama already running outside Docker (native/systemd service) — reusing it."
      OLLAMA_STATUS="reused (native service)"
    else
      OLLAMA_CONFIGFILE="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$OLLAMA_CONTAINER" 2>/dev/null || true)"
      if [ "$OLLAMA_CONFIGFILE" = "$REPO_ROOT/docker-compose.yml" ]; then
        warn "Ollama inherited from the old layout — migrating to $OLLAMA_DIR."
        mkdir -p "$OLLAMA_DIR/data"
        docker rm -f "$OLLAMA_CONTAINER" >/dev/null 2>&1 || true
        # Recover the weights from the inherited named volume: avoids re-downloading the model.
        if docker volume inspect ollama-data >/dev/null 2>&1; then
          echo "Copying weights from the 'ollama-data' volume into $OLLAMA_DIR/data…"
          docker run --rm -v ollama-data:/from -v "$OLLAMA_DIR/data":/to alpine sh -c 'cp -a /from/. /to/' \
            || warn "weight copy failed — $OLLAMA_MODEL will be downloaded again."
        fi
        create_ollama_stack
        OLLAMA_STATUS="migrated to $OLLAMA_DIR ($OLLAMA_CONTAINER)"
      else
        echo "Ollama already running in container '$OLLAMA_CONTAINER' — reusing it, no recreation."
        OLLAMA_STATUS="reused ($OLLAMA_CONTAINER)"
      fi
    fi
  else
    echo "No Ollama answering on :11434."
    restart_stopped_service "ollama/ollama" "Ollama" "http://localhost:11434/api/version" 15 2
    rc=$?
    if [ "$rc" -eq 0 ]; then
      OLLAMA_CONTAINER="$RESTARTED_CONTAINER"
      OLLAMA_STATUS="restarted ($OLLAMA_CONTAINER)"
    elif [ "$rc" -eq 2 ]; then
      OLLAMA_CONTAINER="$RESTARTED_CONTAINER"
      OLLAMA_STATUS="restarted but not answering ($OLLAMA_CONTAINER)"
    elif start_native_ollama; then
      OLLAMA_CONTAINER="native or unidentified service"
      OLLAMA_STATUS="started (native service)"
    elif [ "$NATIVE_OLLAMA_PRESENT" -eq 1 ]; then
      OLLAMA_STATUS="skipped (native Ollama installed but not started)"
    elif port_taken_by_other 11434 "Ollama"; then
      OLLAMA_STATUS="skipped (port 11434 busy)"
    else
      create_ollama_stack
      OLLAMA_STATUS="created ($OLLAMA_CONTAINER, stack $OLLAMA_DIR)"
    fi
  fi

  # --- App web (port 8090) ---
  WEB_CONTAINER=""
  WEB_STATUS=""
  echo "--- Web app (:8090) ---"
  if curl -sf http://localhost:8090/ >/dev/null 2>&1; then
    WEB_CONTAINER="$(find_container_by_port 8090 || true)"
    [ -z "$WEB_CONTAINER" ] && WEB_CONTAINER="unidentified container"
    echo "Web app already running in '$WEB_CONTAINER' — reusing it, no recreation."
    WEB_STATUS="reused ($WEB_CONTAINER)"
  else
    echo "No web app answering on :8090 — creating it via docker compose."
    $COMPOSE up -d ai-content-studio
    WEB_CONTAINER="$(find_container_by_port 8090 || echo "ai-content-studio-web")"
    WEB_STATUS="created ($WEB_CONTAINER)"
  fi

  # --- Updater ---
  UPDATER_STATUS=""
  echo "--- Updater service ---"
  $COMPOSE up -d --build updater >/dev/null 2>&1 && UPDATER_STATUS="started" || UPDATER_STATUS="failed to start (see 'docker compose logs updater')"
  echo "Updater service: $UPDATER_STATUS"

  # -------------------------------------------------------------------------
  section "3/5 Downloading models (scripts/models.txt)"
  # -------------------------------------------------------------------------
  MODELS_FILE="$REPO_ROOT/scripts/models.txt"
  DOWNLOADED_OK=()
  SKIPPED_OK=()
  FAILED_DL=()
  MISSING_MANUAL=()

  mkdir -p "$COMFY_MODELS_DIR" 2>/dev/null || true
  if [ ! -w "$COMFY_MODELS_DIR" ]; then
    warn "model folder is not writable — downloads skipped: $COMFY_MODELS_DIR"
    echo "  Usual cause: folder created by Docker as root (padlock in the file manager)."
    echo "  Fix: sudo chown -R $(id -u):$(id -g) \"$COMFY_DIR\" then run this script again."
  elif [ -f "$MODELS_FILE" ]; then
    while IFS='|' read -r dossier fichier taille url || [ -n "${dossier:-}" ]; do
      [ -z "${dossier:-}" ] && continue
      case "$dossier" in \#*) continue ;; esac
      url="${url%$'\r'}"
      target_dir="$COMFY_MODELS_DIR/$dossier"
      target_path="$target_dir/$fichier"

      if [ -z "$url" ] || [ "$url" = "NON_TROUVE" ]; then
        MISSING_MANUAL+=("$target_path")
        continue
      fi

      if [ -f "$target_path" ] && is_uint "$taille" && [ "$taille" -gt 0 ]; then
        actual_size="$(stat -c '%s' "$target_path" 2>/dev/null || echo 0)"
        if [ "$actual_size" -gt "$taille" ]; then diff=$((actual_size - taille)); else diff=$((taille - actual_size)); fi
        tolerance=$((taille / 100))
        [ "$tolerance" -lt 1 ] && tolerance=1
        if [ "$diff" -le "$tolerance" ]; then
          echo "SKIP (already present, size matches): $target_path"
          SKIPPED_OK+=("$target_path")
          continue
        fi
      fi

      mkdir -p "$target_dir"
      echo "Downloading: $fichier -> $target_path"
      # Some Hugging Face repositories (e.g. Lightricks/LTX-2.5) are "gated": an anonymous
      # download fails with 401 until the terms have been accepted and a token is provided.
      # HF_TOKEN is used when set.
      HF_AUTH_ARGS=()
      if [ -n "${HF_TOKEN:-}" ] && [[ "$url" == *"huggingface.co"* ]]; then
        HF_AUTH_ARGS=(-H "Authorization: Bearer ${HF_TOKEN}")
      fi
      if curl -sfL -C - "${HF_AUTH_ARGS[@]}" -o "$target_path" "$url"; then
        DOWNLOADED_OK+=("$target_path")
      else
        warn "download failed for '$fichier' from $url"
        FAILED_DL+=("$target_path ($url)")
      fi
    done < "$MODELS_FILE"
  else
    echo "scripts/models.txt not found — no model to download for now."
  fi

  # -------------------------------------------------------------------------
  section "4/5 Required Ollama model ($OLLAMA_MODEL)"
  # -------------------------------------------------------------------------
  GEMMA_STATUS="unknown"
  if ! curl -sf http://localhost:11434/api/version >/dev/null 2>&1; then
    warn "Ollama is not answering on :11434 — cannot check or pull $OLLAMA_MODEL."
    echo "  Prompt enrichment and the storyboard/character sheets will not work without it."
    GEMMA_STATUS="Ollama unavailable"
  elif curl -sf http://localhost:11434/api/tags 2>/dev/null | grep -q "\"$OLLAMA_MODEL\""; then
    echo "OK: $OLLAMA_MODEL already present."
    GEMMA_STATUS="present"
  else
    echo "$OLLAMA_MODEL missing — pulling through the Ollama HTTP API (may take several minutes)..."
    # Through the API rather than 'docker exec': same behaviour whether Ollama runs in our
    # container, in another project's, or natively (systemd) — that last case used to leave
    # the model missing without the script noticing.
    curl -s -X POST http://localhost:11434/api/pull -d "{\"model\":\"$OLLAMA_MODEL\"}" -o /dev/null
    # /api/pull answers 200 even when the pull fails mid-stream: check the result again.
    if curl -sf http://localhost:11434/api/tags 2>/dev/null | grep -q "\"$OLLAMA_MODEL\""; then
      GEMMA_STATUS="downloaded"
    else
      warn "$OLLAMA_MODEL pull failed."
      GEMMA_STATUS="failed"
    fi
  fi

  # ComfyUI has just been created: its first start is not instant. Without this wait the
  # script would finish with "OK" while the app cannot generate anything yet.
  if [ "$COMFY_CREATED" -eq 1 ]; then
    echo
    echo "Waiting for ComfyUI on :8188 (first start)…"
    for _ in $(seq 1 60); do
      curl -sf http://localhost:8188/system_stats >/dev/null 2>&1 && break
      sleep 10
    done
    if curl -sf http://localhost:8188/system_stats >/dev/null 2>&1; then
      echo "OK: ComfyUI answers."
    else
      warn "ComfyUI still not answering after 10 min — see 'docker logs comfyui-nvidia'."
    fi
  fi

  # -------------------------------------------------------------------------
  section "5/5 Final summary"
  # -------------------------------------------------------------------------
  echo "Services:"
  echo "  - ComfyUI : ${COMFY_STATUS:-unknown}"
  echo "  - Ollama  : ${OLLAMA_STATUS:-unknown}"
  echo "  - Web     : ${WEB_STATUS:-unknown}"
  echo "  - Updater : ${UPDATER_STATUS:-unknown}"
  echo
  # Actual Ollama storage location: the container's mount when there is one, otherwise
  # nothing useful to print — a native service keeps its weights wherever it likes (~/.ollama).
  OLLAMA_DATA="$(docker inspect --format '{{ range .Mounts }}{{ if eq .Destination "/root/.ollama" }}{{ .Source }}{{ end }}{{ end }}' "$OLLAMA_CONTAINER" 2>/dev/null || true)"
  if [ -z "$OLLAMA_DATA" ]; then
    case "$OLLAMA_STATUS" in
      *native*) OLLAMA_DATA="native service, not managed by this script" ;;
      *)        OLLAMA_DATA="$OLLAMA_DIR" ;;
    esac
  fi
  echo "Locations:"
  echo "  - app     : $REPO_ROOT"
  echo "  - ComfyUI : $COMFY_MODELS_DIR (models)"
  echo "  - Ollama  : $OLLAMA_DATA"
  echo
  echo "Ollama model $OLLAMA_MODEL: $GEMMA_STATUS"
  echo
  echo "ComfyUI models (scripts/models.txt):"
  echo "  - already present (not re-downloaded) : ${#SKIPPED_OK[@]}"
  echo "  - downloaded this run                 : ${#DOWNLOADED_OK[@]}"
  if [ "${#FAILED_DL[@]}" -gt 0 ]; then
    echo "  - download failures:"
    printf '      %s\n' "${FAILED_DL[@]}"
    echo "    (if the failure is a Lightricks/LTX-2.5 file: that Hugging Face repo is 'gated' —"
    echo "    accept its terms on the HF page with your account, then re-run this script as"
    echo "    HF_TOKEN=<your_token> ./install-ubuntu.sh (or ./install-omarchy.sh))"
  fi
  if [ "${#MISSING_MANUAL[@]}" -gt 0 ]; then
    echo "  - to download manually (URL NON_TROUVE, see README):"
    printf '      %s\n' "${MISSING_MANUAL[@]}"
  fi
  echo
  echo "Final health checks:"
  for p in 8188 11434 8090; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${p}/" 2>/dev/null || echo "000")"
    echo "  - :$p -> HTTP $code"
  done
  code_update="000"
  for _ in 1 2 3 4 5; do
    code_update="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:8090/update/status" 2>/dev/null || echo "000")"
    [ "$code_update" = "200" ] && break
    sleep 2
  done
  echo "  - /update/status -> HTTP $code_update"
}
