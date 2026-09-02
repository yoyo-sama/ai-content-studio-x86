# Dell AI Content Studio — démo Media & Entertainment sur GB10

Studio créatif IA **100 % local** : génération d'images (Krea 2, Qwen-Edit) et de vidéos avec audio (LTX 2.5, Minimax H3) via ComfyUI sur un Dell Pro Max GB10, enrichissement de prompt par LLM local (Ollama). L'application est **une seule page statique** (`index.html`) servie par nginx — aucun backend, aucun build, aucun framework.

## Déploiement (clone & run)

### Prérequis

- Machine Linux avec **GPU NVIDIA**, driver installé, et
  [`nvidia-container-toolkit`](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) configuré pour Docker.
- **Docker** + **Docker Compose** (plugin `docker compose`).

### Démarrage

```bash
git clone <url-du-repo> ai-content-studio
cd ai-content-studio
docker compose up -d
```

`docker-compose.yml` définit 3 services :

| Service | Image | Port | Rôle |
|---|---|---|---|
| `ai-content-studio` | `nginx:alpine` | 8090 | Sert `index.html` + reverse-proxy vers ComfyUI/Ollama |
| `comfyui` | `mmartial/comfyui-nvidia-docker:ubuntu24_cuda13.1-dgx-latest` | 8188 | Moteur de génération d'images/vidéos |
| `ollama` | `ollama/ollama:latest` | 11434 | LLM local pour l'enrichissement de prompt |

Les volumes ComfyUI sont montés par défaut sous `./comfyui/` à la racine du repo
(`comfyui/basedir`, `comfyui/run`, `comfyui/userscripts_dir`) — modifiables dans
`docker-compose.yml` si vos modèles vivent déjà ailleurs sur la machine. Le service `ollama`
tire automatiquement le modèle `gemma4:e4b` au démarrage (`ollama pull` est idempotent, il ne
retélécharge pas un modèle déjà présent) ; si besoin, relancez-le manuellement :

```bash
docker compose exec ollama ollama pull gemma4:e4b
```

**Important : les poids de modèles ne sont PAS dans le dépôt Git** (plusieurs dizaines de Go
au total) — à télécharger manuellement dans `comfyui/basedir/models/<dossier>/` selon le
tableau ci-dessous, avant de lancer une génération.

### Health-checks post-démarrage

```bash
curl http://localhost:8090/                    # app statique
curl http://localhost:8188/system_stats         # ComfyUI vivant
curl http://localhost:11434/api/version          # Ollama vivant
```

### Modèles à télécharger

Chaque fichier va dans `comfyui/basedir/models/<dossier>/` (chemin hôte par défaut ; adaptez
si vous avez changé le mapping de volume). Aucune URL n'est indiquée quand elle n'a pas été
vérifiée — cherchez le fichier exact sur Hugging Face (piste : orgs `Comfy-Org`, `black-forest-labs`,
`Lightricks`, `Qwen`, éditeurs des modèles concernés).

#### Pipelines actuels (Krea 2, Qwen-Edit, LTX 2.5, Minimax H3)

Tailles vérifiées, reprises de `docs/NOUVEAUX-MODELES-LOT1.md` (15 fichiers Krea2/LTX2.5/H3,
tous présents et qualifiés lors du LOT 1 ; les 4 lignes Qwen-Edit restent d'un lot antérieur,
tailles non re-vérifiées).

| Modèle / pipeline | Fichier | Dossier cible | Taille |
|---|---|---|---|
| Qwen-Edit | `qwen_image_edit_2509_fp8_e4m3fn.safetensors` | `diffusion_models/` | `<à compléter>` |
| Qwen-Edit (encodeur) | `qwen_2.5_vl_7b_fp8_scaled.safetensors` | `text_encoders/` | `<à compléter>` |
| Qwen-Edit (VAE, partagé Krea 2) | `qwen_image_vae.safetensors` | `vae/` | 243 Mo |
| Qwen-Edit (LoRA Lightning 4 steps) | `Qwen-Image-Edit-2509-Lightning-4steps-V1.0-bf16.safetensors` | `loras/` | `<à compléter>` |
| Krea 2 (transformer) | `krea2_turbo_fp8_scaled.safetensors` | `diffusion_models/` | 13 Go |
| Krea 2 (encodeur) | `qwen3vl_4b_fp8_scaled.safetensors` | `text_encoders/` | 4,9 Go |
| Krea 2 (VAE, partagé Qwen-Edit) | `qwen_image_vae.safetensors` | `vae/` | 243 Mo |
| LTX 2.5 (transformer distillé) | `ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors` | `diffusion_models/` | 21 Go |
| LTX 2.5 (VAE vidéo) | `ltx-2.5-video-vae-bf16.safetensors` | `vae/` | 1,4 Go |
| LTX 2.5 (VAE audio) | `ltx-2.5-audio-vae-bf16.safetensors` | `vae/` | 348 Mo |
| LTX 2.5 (encodeur principal) | `gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors` | `text_encoders/` | 15 Go |
| LTX 2.5 (encodeur enhancer prompt) | `gemma4_e2b_it_bf16.safetensors` | `text_encoders/` | 9,6 Go |
| LTX 2.5 (upscaler latent x2, t2v/i2v uniquement) | `ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors` | `latent_upscale_models/` | 950 Mo |
| Minimax H3 t2v/i2v (transformer) | `minimax_h3_fl2va_pruned_w4a8_mixed.safetensors` | `diffusion_models/` | 12 Go |
| Minimax H3 r2v (transformer, checkpoint différent) | `minimax_h3_ref2va_pruned_w4a8_mixed.safetensors` | `diffusion_models/` | 11 Go |
| Minimax H3 (encodeur) | `qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors` | `text_encoders/` | 15 Go |
| Minimax H3 (VAE vidéo) | `minimax_h3_video_vae_fp16.safetensors` | `vae/` | 4,9 Go |
| Minimax H3 (VAE audio) | `minimax_h3_audio_vae_fp32.safetensors` | `vae/` | 578 Mo |
| Minimax H3 (LoRA turbo, t2v/i2v/r2v) | `minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors` | `loras/H3/` | 592 Mo |

> Emplacement des URLs de téléchargement non vérifiées : voir Hugging Face, orgs `Comfy-Org` /
> `Lightricks` (LTX) / éditeur Minimax pour H3 — aucun lien n'est fourni ici tant qu'il n'a pas
> été vérifié manuellement, pour éviter de pointer vers un mauvais fichier.

> **Modèles legacy** (Flux2 Klein 9B, Ernie-Image, Z-Image, LTX 2.3) : plus utilisés par
> l'app (:8090), mais toujours référencés par les workflows UI drag-drop `workflows/*.json`
> (`campaign_generator.json`, `storyboard_animatic.json`, `ernie_turbo.json`, `ernie_quality.json`,
> `localized_assets.json`) — voir `workflows/README.md` si vous voulez encore les charger
> directement dans ComfyUI.

### Modèle Ollama requis

`gemma4:e4b` — tiré automatiquement au démarrage du service `ollama` (voir plus haut), ou
manuellement :

```bash
docker compose exec ollama ollama pull gemma4:e4b
```

## Les 3 scénarios (cf. spec `ai_content_studio_media_entertainment_gb10.md`)

| Scénario | Pipelines dédiés | Livrables |
|---|---|---|
| **Campaign Generator** | `campaign_full` (une tâche) + pipelines génériques | Posters 2:3, thumbnails 16:9, social 1:1, teaser vidéo vertical avec audio |
| **Storyboard + Animatic** | `storyboard_v2` (charsheet+locsheet+keyframes+cuts), `reference2video` (Minimax H3, 1 seul job), `sequence2video` (FLF2V manuel) | Storyboard N plans + animatic assemblé, OU vidéo unique personnage+décor cohérents, OU animatic first-frame→last-frame manuel, avec audio |
| **Localized Assets** | image2image + marchés cibles | Variantes par plaque (North America, Europe, Middle East, Asia…) via Qwen-Edit |

Une couche de **navigation par profils métiers** (Réalisateur/Storyboard artist, DA/Motion designer,
Social media/Marketing, Monteur/Post-production) présélectionne scénario + pipeline sans changer le
routing ci-dessus.

Pipelines génériques disponibles partout : text2image (Krea 2 Turbo), image2image (Qwen-Edit 2509),
text2video et image2video (LTX 2.5 et Minimax H3, au choix dans le menu Modèle ; audio natif
optionnel, turbo Minimax H3 activable).

## Arborescence

```
index.html                  ← TOUTE l'application (CSS + HTML + JS)
docker-compose.yml          ← 3 services : nginx (8090), comfyui (8188), ollama (11434)
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
