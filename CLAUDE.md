# CLAUDE.md — guide agent pour AI Content Studio

Démo Dell GB10 : page statique unique (`index.html`) qui pilote ComfyUI (`:8188`) et Ollama (`:11434`). Pas de build, pas de dépendances, pas de backend. Publique via nginx sur `:8090` (`docker compose up -d`).

## Commandes essentielles

```bash
docker compose up -d                                  # servir l'app (nginx :8090)
curl -s http://localhost:8188/system_stats | head -c 200   # ComfyUI vivant ?
curl -s http://localhost:11434/api/version                 # Ollama vivant ?
node --check <(python3 -c "import re;print(re.search(r'<script>(.*)</script>', open('index.html').read(), re.S).group(1))")   # valider le JS
python3 tools/convert.py workflows/storyboard_animatic.json > /tmp/api.json   # UI→API (brut)
python3 tools/onboard.py <ui.json> --id X --label "…" --pipeline text2video --model "…"   # UI→API+placeholders+manifest+test
python3 tools/validate.py workflows/api/ltx_t2v.json --reduce --frames 0,12 --audio       # rendu réel réduit + inspection
```

Modèles installés : `ls /home/sparks/comfyui-spark/basedir/models/<dossier>/` (diffusion_models, checkpoints, text_encoders, vae, loras, latent_upscale_models). Ne jamais référencer un `.safetensors` sans vérifier sa présence.

## Règles du projet (imposées par l'utilisateur)

- **Core ComfyUI nodes uniquement** — aucun custom node.
- **Simplest thing that works** — pas de feature/abstraction/validation au-delà du demandé.
- Enrichissement de prompt : **exclusivement `gemma4:e4b`** via Ollama (ne pas exposer d'autres LLM locaux).
- Clés API cloud : **sessionStorage uniquement** (jamais localStorage, jamais loguées).
- Restriction pipeline↔scénario : via `pipelines[].scenario` dans `manifest.json` (manifest v2), pas en JS.
- Le journal d'événements n'est pas traduit (choix assumé) ; tout le reste de l'UI est i18n FR/EN/ES/DE.

## Où est quoi dans index.html

Un seul fichier, trois zones : `<style>` (variables CSS + `:root[data-theme="dark"]`), HTML, `<script>` (~1 950 lignes). Repères JS par commentaires `// ── Section ──` : config/RATIOS/PIPELINE_*, i18n (I18N + translateTree), manifest & menus (refreshPipelineOptions/updateModelOptions), scénarios, WebSocket+jobs, galerie (addAssetCard/groupFor/lightbox/prompts), Generate (handler + tryCloudGeneration), enrichissement Ollama, cloud (OpenAI/Gemini), marchés, **builders de graphes API** (makeGraphBuilder, addLtxShared, addFLF2VChain, addFluxShot, addErnieShot, addGrid, buildCampaignFullGraph, applyLtxAudio, mergeGraph), **storyboard_v2** (orchestration multi-jobs : characterSheetFromBrief/shotListFromBrief, submitCharsheetJob/submitKeyframeJob/submitGridJob/submitCutJob/submitAnimaticJob, generateStoryboardV2 mode Auto + directorStep1/2/3 mode Réalisateur), séquence FLF2V manuelle, monitor. Détails : `docs/ARCHITECTURE.md`.

## Pièges critiques (résumé — détail dans docs/LESSONS.md)

- Flux2 Klein **9B** exige l'encodeur `qwen_3_8b_fp8mixed` (le `qwen_3_4b` des templates 4B → crash dims 7680 vs 12288).
- `LTXVAddGuide` **recadre brutalement** toute image guide au ratio ≠ latent → toujours `ImageScale(crop:"center")` avant.
- L'audio LTX 2.3 ne demande **aucun modèle en plus** (audio VAE dans le checkpoint) ; câblage précis dans LESSONS.
- LTX 2.3 distillé = **cfg 1** → l'adhérence au prompt repose entièrement sur l'enhancer intégré `TextGenerateLTX2Prompt` (+ LoRA gemma abliterated sur l'encodeur) — ne jamais le retirer d'un graphe LTX.
- `ComfyMathExpression` : slot 0 = FLOAT, slot 1 = INT.
- Ids de graphe non numériques possibles ("PH") → filtrer avant `Math.max` pour générer des ids.
- La hauteur vidéo LTX est arrondie au multiple de 32 inférieur (720 → 704) ; les frames vidéo aussi, au 8n+1 inférieur (2 s@25fps calculé 51 → rendu réel 49).
- Prompt Qwen-Edit : bannir tout vocabulaire "storyboard/keyframe" (fait dessiner une planche annotée) — tout exprimer positivement (cfg 1 → negative ignoré).
- `storyboard_v2` : les cuts LTX i2v dérivaient souvent vers un contenu sans rapport (~4/9 sur le run N=8, prompt = `shot.motion` seul, enhancer `TextGenerateLTX2Prompt` sans entrée image à cfg 1). **Corrigé** : `submitCutJob` ancre le prompt sur `${scene}. ${charDesc}. ${locDesc}. Camera motion: ${motion}.` — vérifié 0 dérive sur le run qualifié LOT 4 (ancrage double). Ne jamais revenir à un prompt de mouvement seul. Détail : LESSONS piège n°9.
- `storyboard_v2` ancrage double (`qwen_edit_dual.json`) : l'image 1 (charsheet) alimente le conditioning ET le latent de départ (`VAEEncode`) ; l'image 2 (locsheet) ne doit alimenter QUE le conditioning (`TextEncodeQwenImageEditPlus`) — jamais `VAEEncode`, sinon la géométrie de départ vient du décor et non du personnage. Détail : LESSONS piège n°10.
- L'ancrage Qwen-Edit (`storyboard_v2`) ne suit **pas** les angles de caméra forts (zénithal, contre-plongée extrême) : il préserve la pose/composition de l'image de référence. Sans impact en usage normal (gemma ne propose pas ce type d'angle) — détail dans LESSONS piège n°8.

## Validation obligatoire avant de livrer

La validation structurelle (nœuds dans `/object_info`, modèles sur disque, liens intègres) **ne suffit pas** : un rendu "success" peut être visuellement/sonorement faux. Toujours faire un rendu réel réduit (frames vidéo ≈ 25) puis inspecter frames et piste audio — méthode outillée dans `docs/TESTING.md`. Pour l'UI : captures headless Chromium (chemin du binaire dans TESTING) en clair/sombre et à 390/768/1250/1440 px.
