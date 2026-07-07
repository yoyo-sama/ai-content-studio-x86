# Dell AI Content Studio — démo Media & Entertainment sur GB10

Studio créatif IA **100 % local** : génération d'images (Flux2, Ernie, Z-Image, Qwen-Edit) et de vidéos avec audio (LTX 2.3) via ComfyUI sur un Dell Pro Max GB10, enrichissement de prompt par LLM local (Ollama). L'application est **une seule page statique** (`index.html`) servie par nginx — aucun backend, aucun build, aucun framework.

## Démarrage

```bash
cd ~/ai-content-studio
docker compose up -d        # nginx → http://localhost:8090
```

Prérequis (conteneurs indépendants, normalement déjà en service avec restart policy) :
- **ComfyUI 0.24+** sur `:8188` (conteneur `comfyui-nvidia`) — modèles sur l'hôte dans `/home/sparks/comfyui-spark/basedir/models/`
- **Ollama** sur `:11434` (conteneur `ollama-api`) — modèle requis : `gemma4:e4b`

Après un reboot, seul le nginx du studio doit être relancé manuellement (`docker compose up -d`).

## Les 3 scénarios (cf. spec `ai_content_studio_media_entertainment_gb10.md`)

| Scénario | Pipelines dédiés | Livrables |
|---|---|---|
| **Campaign Generator** | `campaign_full` (une tâche) + pipelines génériques | Posters 2:3, thumbnails 16:9, social 1:1, teaser vidéo vertical avec audio |
| **Storyboard + Animatic** | `storyboard_full`, `sequence2video` (FLF2V) | N shots (découpage du brief par gemma), grille contact-sheet, animatic first-frame→last-frame avec audio |
| **Localized Assets** | image2image + marchés cibles | Variantes par plaque (North America, Europe, Middle East, Asia…) via Qwen-Edit |

Pipelines génériques disponibles partout : text2image (Flux2 / Ernie / Z-Image), image2image (Qwen-Edit), text2video et image2video (LTX 2.3, audio optionnel).

## Arborescence

```
index.html                  ← TOUTE l'application (CSS + HTML + JS)
docker-compose.yml          ← nginx statique (port 8090)
workflows/
  manifest.json             ← alimente les menus Pipeline/Modèle de l'app
  api/*.json                ← templates API mono-branche avec placeholders {{PROMPT}}…
  *.json                    ← workflows complets format UI (drag-drop dans ComfyUI)
  README.md                 ← détail des workflows
tools/convert.py            ← convertisseur UI→API (voir docs/TESTING.md)
docs/
  ARCHITECTURE.md           ← anatomie de l'app et des formats
  LESSONS.md                ← pièges & patterns validés (LIRE AVANT DE MODIFIER)
  TESTING.md                ← méthode de validation (rendus réels, extraction frames/audio)
ai_content_studio_media_entertainment_gb10.md   ← spec fonctionnelle d'origine
dell_ai_content_studio_prototype.html           ← ancien prototype (legacy, non utilisé)
```

## Reprise du projet

1. Lire `CLAUDE.md` (conventions et commandes), puis `docs/LESSONS.md` **avant toute modification des graphes ComfyUI** — les pièges y sont coûteux à redécouvrir.
2. Toute modification de génération doit être validée par un **rendu réel** ET une **inspection visuelle/audio** du résultat (méthode dans `docs/TESTING.md`) — un job "success" peut produire un contenu faux.
3. L'UI se vérifie en headless Chromium (captures multi-résolutions, thèmes clair/sombre) — voir `docs/TESTING.md`.
