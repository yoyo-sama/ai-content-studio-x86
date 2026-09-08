#!/usr/bin/env bash
# lib-install-common.sh — logique partagée par install-ubuntu.sh et install-omarchy.sh.
# Détecte les 3 services (web/comfyui/ollama) par rôle réel (santé HTTP), pas par nom
# de conteneur ; réutilise tout ce qui tourne déjà ; ne recrée/ne détruit jamais un
# conteneur qu'on ne possède pas. Seule la vérification des prérequis système (section
# 1/5) diffère entre distributions — elle vit dans chaque script appelant, pas ici.
#
# Contrat avec le script appelant : définir REPO_ROOT et COMPOSE, puis `source` ce
# fichier et appeler check_docker_common() puis run_install().

section() { printf '\n=== %s ===\n' "$*"; }
warn()    { printf 'AVERTISSEMENT: %s\n' "$*"; }

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Retrouve le conteneur qui répond réellement sur un port donné :
# 1) via le mapping de port publié (docker ps --filter publish=PORT)
# 2) sinon, parmi les conteneurs en network_mode: host, celui dont un bind-mount
#    correspond à la racine de CE repo (cas de notre nginx en network_mode host).
find_container_by_port() {
  local port="$1" name c
  name=$(docker ps --filter "publish=${port}" --format '{{.Names}}' 2>/dev/null | head -n1)
  if [ -n "$name" ]; then
    printf '%s\n' "$name"
    return 0
  fi
  for c in $(docker ps --filter "network=host" --format '{{.Names}}' 2>/dev/null); do
    if docker inspect --format '{{json .Mounts}}' "$c" 2>/dev/null | grep -qF "\"Source\":\"${REPO_ROOT}\""; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

# Partie de la vérification d'environnement commune aux deux distros (docker,
# docker compose plugin, runtime nvidia). L'appelant fait le reste (paquets
# système spécifiques à sa distro) avant/après cet appel.
check_docker_common() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERREUR: 'docker' introuvable dans le PATH. Installez Docker avant de relancer ce script." >&2
    exit 1
  fi
  if ! docker compose version >/dev/null 2>&1; then
    echo "ERREUR: le plugin 'docker compose' (v2) est introuvable. Installez-le avant de relancer ce script." >&2
    exit 1
  fi
  echo "OK: docker + docker compose disponibles."

  if docker info >/dev/null 2>&1 && docker info 2>/dev/null | grep -qi 'nvidia'; then
    echo "OK: runtime nvidia détecté par 'docker info'."
  elif command -v nvidia-smi >/dev/null 2>&1; then
    echo "OK: 'nvidia-smi' disponible (nvidia-container-toolkit probablement installé)."
  else
    warn "impossible de confirmer la présence de nvidia-container-toolkit. Les services GPU (ComfyUI/Ollama) pourraient échouer au démarrage. Poursuite du script."
  fi
}

# Détection + (re)création idempotente des 3 services applicatifs + updater,
# téléchargement des modèles, pull du modèle Ollama, récapitulatif final.
run_install() {
  # -------------------------------------------------------------------------
  section "2/5 Détection des services par rôle réel (santé HTTP), pas par nom"
  # -------------------------------------------------------------------------
  COMFY_MODELS_DIR="$REPO_ROOT/comfyui/models"
  COMFY_CONTAINER=""
  COMFY_STATUS=""

  echo "--- ComfyUI (:8188) ---"
  if curl -sf http://localhost:8188/system_stats >/dev/null 2>&1; then
    COMFY_CONTAINER="$(find_container_by_port 8188 || true)"
    if [ -z "$COMFY_CONTAINER" ]; then
      warn "ComfyUI répond sur :8188 mais aucun conteneur correspondant n'a pu être identifié formellement. Réutilisation du service tel quel, sans gestion de conteneur."
      COMFY_STATUS="réutilisé (conteneur non identifié)"
    else
      echo "ComfyUI déjà en service dans le conteneur '$COMFY_CONTAINER' — réutilisation, pas de recréation."
      COMFY_STATUS="réutilisé ($COMFY_CONTAINER)"

      IMAGE="$(docker inspect --format '{{.Config.Image}}' "$COMFY_CONTAINER" 2>/dev/null || true)"
      PROJECT="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$COMFY_CONTAINER" 2>/dev/null || true)"
      CONFIGFILE="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$COMFY_CONTAINER" 2>/dev/null || true)"

      if [ "$CONFIGFILE" = "$REPO_ROOT/docker-compose.yml" ]; then
        echo "Conteneur géré par CE docker-compose.yml — reconstruction éventuelle + recreate si l'image ComfyUI officielle a changé."
        if $COMPOSE build comfyui; then
          echo "Image comfyui (build local) à jour."
        else
          warn "échec de 'docker compose build comfyui' — poursuite avec l'image locale déjà présente."
        fi
        $COMPOSE up -d --force-recreate comfyui
        NEW_NAME="$(find_container_by_port 8188 || true)"
        [ -n "$NEW_NAME" ] && COMFY_CONTAINER="$NEW_NAME"
        COMFY_STATUS="mis à jour ($COMFY_CONTAINER)"
      else
        warn "conteneur ComfyUI trouvé mais géré par un AUTRE projet compose (projet='${PROJECT:-aucun}', fichier='${CONFIGFILE:-aucun/hors-compose}', image='${IMAGE:-inconnue}')."
        echo "  Pas de mise à jour automatique : on ne touche jamais à un conteneur qu'on ne possède pas."
      fi

      # Chemin réel d'après le bind-mount effectif du conteneur (utile même si
      # le conteneur appartient à un autre projet compose).
      REAL_MODELS="$(docker inspect --format '{{ range .Mounts }}{{ if eq .Destination "/comfyui/models" }}{{ .Source }}{{ end }}{{ end }}' "$COMFY_CONTAINER" 2>/dev/null || true)"
      if [ -n "$REAL_MODELS" ]; then
        COMFY_MODELS_DIR="$REAL_MODELS"
        echo "Chemin réel détecté : models=$COMFY_MODELS_DIR"
      else
        warn "montage /comfyui/models introuvable sur ce conteneur — dépôt des modèles à faire manuellement pour ce conteneur."
      fi
    fi
  else
    echo "Aucun ComfyUI ne répond sur :8188 — construction + création via docker compose."
    $COMPOSE build comfyui && $COMPOSE up -d comfyui
    COMFY_CONTAINER="$(find_container_by_port 8188 || echo "comfyui-nvidia")"
    COMFY_STATUS="créé ($COMFY_CONTAINER)"
  fi

  # --- Ollama (port 11434) ---
  OLLAMA_CONTAINER=""
  OLLAMA_STATUS=""
  echo "--- Ollama (:11434) ---"
  if curl -sf http://localhost:11434/api/version >/dev/null 2>&1; then
    OLLAMA_CONTAINER="$(find_container_by_port 11434 || true)"
    [ -z "$OLLAMA_CONTAINER" ] && OLLAMA_CONTAINER="(inconnu)"
    echo "Ollama déjà en service dans '$OLLAMA_CONTAINER' — réutilisation, pas de recréation."
    OLLAMA_STATUS="réutilisé ($OLLAMA_CONTAINER)"
  else
    echo "Aucun Ollama ne répond sur :11434 — création via docker compose."
    $COMPOSE up -d ollama
    OLLAMA_CONTAINER="$(find_container_by_port 11434 || echo "ollama-api")"
    OLLAMA_STATUS="créé ($OLLAMA_CONTAINER)"
  fi

  # --- App web (port 8090) ---
  WEB_CONTAINER=""
  WEB_STATUS=""
  echo "--- App web (:8090) ---"
  if curl -sf http://localhost:8090/ >/dev/null 2>&1; then
    WEB_CONTAINER="$(find_container_by_port 8090 || true)"
    [ -z "$WEB_CONTAINER" ] && WEB_CONTAINER="(inconnu)"
    echo "App web déjà en service dans '$WEB_CONTAINER' — réutilisation, pas de recréation."
    WEB_STATUS="réutilisé ($WEB_CONTAINER)"
  else
    echo "Aucune app web ne répond sur :8090 — création via docker compose."
    $COMPOSE up -d ai-content-studio
    WEB_CONTAINER="$(find_container_by_port 8090 || echo "ai-content-studio-web")"
    WEB_STATUS="créé ($WEB_CONTAINER)"
  fi

  # --- Module de mise à jour (updater) ---
  UPDATER_STATUS=""
  echo "--- Module de mise à jour (updater) ---"
  $COMPOSE up -d updater >/dev/null 2>&1 && UPDATER_STATUS="démarré" || UPDATER_STATUS="échec du démarrage (voir 'docker compose logs updater')"
  echo "Service updater : $UPDATER_STATUS"

  # -------------------------------------------------------------------------
  section "3/5 Téléchargement des modèles (scripts/models.txt)"
  # -------------------------------------------------------------------------
  MODELS_FILE="$REPO_ROOT/scripts/models.txt"
  DOWNLOADED_OK=()
  SKIPPED_OK=()
  FAILED_DL=()
  MISSING_MANUAL=()

  if [ -f "$MODELS_FILE" ]; then
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
          echo "SKIP (déjà présent, taille conforme): $target_path"
          SKIPPED_OK+=("$target_path")
          continue
        fi
      fi

      mkdir -p "$target_dir"
      echo "Téléchargement: $fichier -> $target_path"
      # Certains dépôts Hugging Face (ex. Lightricks/LTX-2.5) sont "gated" : un
      # téléchargement anonyme échoue en 401 tant que les conditions n'ont pas été
      # acceptées sur huggingface.co avec un compte, et qu'un jeton d'accès n'est
      # pas fourni. Si HF_TOKEN est défini dans l'environnement, on l'utilise ;
      # sinon les fichiers gated échoueront proprement et remonteront dans la
      # liste des échecs du récapitulatif, sans bloquer les autres téléchargements.
      HF_AUTH_ARGS=()
      if [ -n "${HF_TOKEN:-}" ] && [[ "$url" == *"huggingface.co"* ]]; then
        HF_AUTH_ARGS=(-H "Authorization: Bearer ${HF_TOKEN}")
      fi
      if curl -sfL -C - "${HF_AUTH_ARGS[@]}" -o "$target_path" "$url"; then
        DOWNLOADED_OK+=("$target_path")
      else
        warn "échec du téléchargement de '$fichier' depuis $url"
        FAILED_DL+=("$target_path ($url)")
      fi
    done < "$MODELS_FILE"
  else
    echo "scripts/models.txt introuvable — aucun modèle à télécharger pour l'instant."
  fi

  # -------------------------------------------------------------------------
  section "4/5 Modèle Ollama requis (gemma4:e4b)"
  # -------------------------------------------------------------------------
  GEMMA_STATUS="inconnu"
  if [ "$OLLAMA_CONTAINER" = "(inconnu)" ]; then
    warn "conteneur Ollama non identifié — impossible de lancer 'ollama pull' automatiquement. Vérifiez manuellement."
  else
    if curl -sf http://localhost:11434/api/tags 2>/dev/null | grep -q '"gemma4:e4b"'; then
      echo "OK: gemma4:e4b déjà présent."
      GEMMA_STATUS="présent"
    else
      echo "gemma4:e4b absent — pull en cours dans '$OLLAMA_CONTAINER' (peut prendre plusieurs minutes)..."
      if docker exec "$OLLAMA_CONTAINER" ollama pull gemma4:e4b; then
        GEMMA_STATUS="téléchargé"
      else
        warn "échec du pull de gemma4:e4b."
        GEMMA_STATUS="échec"
      fi
    fi
  fi

  # -------------------------------------------------------------------------
  section "5/5 Récapitulatif final"
  # -------------------------------------------------------------------------
  echo "Services :"
  echo "  - ComfyUI : ${COMFY_STATUS:-inconnu}"
  echo "  - Ollama  : ${OLLAMA_STATUS:-inconnu}"
  echo "  - Web     : ${WEB_STATUS:-inconnu}"
  echo "  - Updater : ${UPDATER_STATUS:-inconnu}"
  echo
  echo "Modèle Ollama gemma4:e4b : $GEMMA_STATUS"
  echo
  echo "Modèles ComfyUI (scripts/models.txt) :"
  echo "  - déjà présents (non retéléchargés) : ${#SKIPPED_OK[@]}"
  echo "  - téléchargés cette exécution       : ${#DOWNLOADED_OK[@]}"
  if [ "${#FAILED_DL[@]}" -gt 0 ]; then
    echo "  - échecs de téléchargement :"
    printf '      %s\n' "${FAILED_DL[@]}"
    echo "    (si l'échec concerne un fichier Lightricks/LTX-2.5 : ce dépôt Hugging Face est"
    echo "    'gated' — acceptez les conditions sur sa page HF avec votre compte, puis relancez"
    echo "    ce script avec HF_TOKEN=<votre_jeton> ./install-ubuntu.sh (ou install-omarchy.sh))"
  fi
  if [ "${#MISSING_MANUAL[@]}" -gt 0 ]; then
    echo "  - à télécharger manuellement (URL NON_TROUVE, voir README) :"
    printf '      %s\n' "${MISSING_MANUAL[@]}"
  fi
  echo
  echo "Health-checks finaux :"
  for p in 8188 11434 8090; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${p}/" 2>/dev/null || echo "000")"
    echo "  - :$p -> HTTP $code"
  done
  code_update="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:8090/update/status" 2>/dev/null || echo "000")"
  echo "  - /update/status -> HTTP $code_update"
}
