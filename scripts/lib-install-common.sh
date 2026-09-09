#!/usr/bin/env bash
# lib-install-common.sh — logique partagée par install-ubuntu.sh et install-omarchy.sh.
# Détecte les services par rôle réel (santé HTTP), pas par nom de conteneur ; réutilise
# tout ce qui tourne déjà — y compris un Ollama installé nativement (systemd), qui n'est
# pas un conteneur ; ne recrée/ne détruit jamais un service qu'on ne possède pas.
# Seule la vérification des prérequis système (section 1/5) diffère entre distributions :
# elle vit dans chaque script appelant, pas ici.
#
# Structure déployée (une stack par service, à la racine du home) :
#   ~/<repo>    app : nginx :8090 + updater
#   ~/comfyui   ComfyUI :8188  (gabarit docker/stacks/comfyui.yml)
#   ~/ollama    Ollama :11434  (gabarit docker/stacks/ollama.yml)
#
# Contrat avec le script appelant : définir REPO_ROOT et COMPOSE, puis `source` ce
# fichier et appeler check_docker_common() puis run_install().
#
# Commentaires en français (comme le reste du dépôt), sortie terminal en anglais.

COMFY_DIR="$HOME/comfyui"
OLLAMA_DIR="$HOME/ollama"
COMFY_IMAGE="ai-content-studio-comfyui:local"
OLLAMA_MODEL="gemma4:e4b"

section() { printf '\n=== %s ===\n' "$*"; }
warn()    { printf 'WARNING: %s\n' "$*"; }

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Retrouve le conteneur qui répond réellement sur un port donné :
# 1) via le mapping de port publié (docker ps --filter publish=PORT)
# 2) sinon, parmi les conteneurs en network_mode: host, celui qui sert ce repo à nginx
#    (l'updater monte lui aussi la racine du repo — la destination les distingue).
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

# Le port est-il tenu par un processus quelconque (docker ou non) ?
port_busy() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH "sport = :$1" 2>/dev/null | grep -q .
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && exec 3>&-
  fi
}

# Refuse de créer une stack quand le port est déjà pris par autre chose que le service
# attendu : sans ça, docker échoue sur « port is already allocated », message opaque.
port_taken_by_other() {   # $1=port  $2=nom lisible du service
  port_busy "$1" || return 1
  warn "port $1 is in use but $2 does not answer its health check."
  echo "  Another process holds it — a native install that is stopped or broken, or another service."
  echo "  Free the port or start that service, then run this script again. Nothing was created."
  return 0
}

# Partie de la vérification d'environnement commune aux deux distros (docker, plugin
# compose, runtime nvidia). L'appelant fait le reste (paquets système de sa distro).
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
  # Dossiers créés AVANT le conteneur : un bind-mount dont la source n'existe pas encore
  # est créé par dockerd en root:root — dossier cadenassé côté utilisateur, et tous les
  # téléchargements de modèles échouent ensuite en « permission denied ».
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
}

# Détection + (re)création idempotente des services, téléchargement des modèles, pull du
# modèle Ollama, récapitulatif final.
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
        # Conteneur créé par l'ANCIENNE mise en page (services comfyui/ollama dans le
        # compose de l'app, volumes sous $REPO_ROOT/comfyui). On le remplace par la stack.
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

      # Chemin réel d'après le bind-mount effectif du conteneur (utile même si le
      # conteneur appartient à un autre projet compose).
      REAL_MODELS="$(docker inspect --format '{{ range .Mounts }}{{ if eq .Destination "/comfyui/models" }}{{ .Source }}{{ end }}{{ end }}' "$COMFY_CONTAINER" 2>/dev/null || true)"
      if [ -n "$REAL_MODELS" ]; then
        COMFY_MODELS_DIR="$REAL_MODELS"
        echo "Actual path detected: models=$COMFY_MODELS_DIR"
      else
        warn "/comfyui/models mount not found on this container — deploy models manually for it."
      fi
    fi
  else
    echo "No ComfyUI answering on :8188."
    if port_taken_by_other 8188 "ComfyUI"; then
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
      # Cas courant sur Ubuntu/Omarchy : Ollama installé par le script officiel, servi
      # par systemd. Ce n'est pas un conteneur — on le réutilise tel quel, et le modèle
      # se tire par l'API HTTP (étape 4/5), pas par 'docker exec'.
      OLLAMA_CONTAINER="native or unidentified service"
      echo "Ollama already running outside Docker (native/systemd service) — reusing it."
      OLLAMA_STATUS="reused (native service)"
    else
      OLLAMA_CONFIGFILE="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$OLLAMA_CONTAINER" 2>/dev/null || true)"
      if [ "$OLLAMA_CONFIGFILE" = "$REPO_ROOT/docker-compose.yml" ]; then
        warn "Ollama inherited from the old layout — migrating to $OLLAMA_DIR."
        mkdir -p "$OLLAMA_DIR/data"
        docker rm -f "$OLLAMA_CONTAINER" >/dev/null 2>&1 || true
        # Reprise des poids du volume nommé hérité : évite de retélécharger le modèle.
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
    if command -v ollama >/dev/null 2>&1; then
      # Ollama est installé nativement mais ne répond pas : créer un conteneur ici
      # provoquerait une bagarre sur le port 11434 au prochain démarrage du service.
      warn "the 'ollama' command exists on this host but the service does not answer."
      echo "  Start it, then run this script again:"
      echo "    sudo systemctl enable --now ollama   # or: ollama serve"
      echo "  No Ollama container was created, to avoid two Ollama instances fighting over port 11434."
      OLLAMA_STATUS="skipped (native Ollama installed but not running)"
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
      # Certains dépôts Hugging Face (ex. Lightricks/LTX-2.5) sont « gated » : un
      # téléchargement anonyme échoue en 401 tant que les conditions n'ont pas été
      # acceptées et qu'aucun jeton n'est fourni. HF_TOKEN est utilisé s'il existe.
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
    # Par l'API et non 'docker exec' : identique que Ollama tourne dans notre conteneur,
    # dans celui d'un autre projet, ou nativement (systemd) — ce dernier cas laissait le
    # modèle absent sans que le script s'en aperçoive.
    curl -s -X POST http://localhost:11434/api/pull -d "{\"model\":\"$OLLAMA_MODEL\"}" -o /dev/null
    # /api/pull répond 200 même quand le tirage échoue en cours de flux : on revérifie.
    if curl -sf http://localhost:11434/api/tags 2>/dev/null | grep -q "\"$OLLAMA_MODEL\""; then
      GEMMA_STATUS="downloaded"
    else
      warn "$OLLAMA_MODEL pull failed."
      GEMMA_STATUS="failed"
    fi
  fi

  # ComfyUI vient d'être créé : son premier démarrage n'est pas instantané. Sans cette
  # attente le script se terminerait « OK » alors que l'app ne peut encore rien générer.
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
  # Emplacement réel du stockage Ollama : le montage du conteneur quand il y en a un,
  # sinon rien à afficher — un service natif range ses poids où il veut (~/.ollama).
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
