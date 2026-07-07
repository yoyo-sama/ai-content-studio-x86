# ComfyUI Workflows — AI Content Studio (GB10)

Deux familles de fichiers :
- **Racine** : workflows complets au format UI, à glisser-déposer dans ComfyUI (http://localhost:8188).
- **`api/` + `manifest.json`** : templates mono-branche au format API avec placeholders (`{{PROMPT}}`, `{{SEED}}`, `{{WIDTH}}`, `{{HEIGHT}}`, `{{BATCH}}`, `{{DURATION}}`, `{{FRAMES}}`, `{{IMAGE}}`), consommés par l'UI du studio (http://localhost:8090) qui alimente ses menus Pipeline/Modèle depuis le manifest. Sorties préfixées `studio/`.

Fonctions construites dynamiquement par l'UI (pas de template statique) :
- **Animatic multi-images FLF2V** : pipeline `sequence2video` du menu (entrée `flf2v_chain` du manifest, `file: null`, construit par `buildFLF2VGraph` en JS) — 2 à 6 images (upload ou galerie), durée par segment (1–8 s, frames 8n+1), ratio appliqué, soumis via le bouton Generate → `studio/sequence`. Le formulaire s'adapte : la section séquence n'apparaît que pour ce pipeline ; variantes/durée globale/image d'entrée/marchés masqués selon le pipeline.
- **Marchés cibles Localized Assets** (pipeline image2image) : un job par marché sélectionné (North America, Latin America, Europe, Middle East, Africa, Asia) avec adaptation culturelle du prompt, seeds décalés.
- **Storyboard complet** (pipeline `storyboard_full`, scénario Storyboard) : une seule tâche = N shots Flux2 (2–6 cases, prompts dérivés du brief par gemma4:e4b avec repli angles standards) + grille `ImageStitch` + animatic FLF2V chaîné avec audio → `studio/story/`.
- **Campagne complète** (pipeline `campaign_full`, scénario Campaign) : une seule tâche = posters 2:3 + thumbnails 16:9 (× variantes) + social 1:1 + teaser vertical LTX (2 passes + upscale, audio) → `studio/campaign/`.

Tout est core-nodes-only (aucun custom node).

| Fichier | Use case | Modèles |
|---|---|---|
| `campaign_generator.json` | Campagne complète : 3 posters 2:3, 3 thumbnails 16:9, 1 visuel social 1:1, 1 teaser vidéo vertical, + 1 poster Ernie Turbo (branche de comparaison) | Flux2 Klein 9B (images) + LTX 2.3 22B (vidéo) + Ernie Turbo |
| `storyboard_animatic.json` | 6 keyframes de storyboard 16:9 + grille contact-sheet + **vidéo complète ~10 s** : chaîne FLF2V de 5 segments (shot1→shot2→…→shot6, chaque keyframe = première/dernière frame du segment) concaténés en `storyboard/full_animatic.mp4` | Flux2 Klein 9B (keyframes) + LTX 2.3 22B FLF2V (vidéo) |
| `localized_assets.json` | Déclinaison d'un asset maître pour 4 marchés (France, Japon, Brésil, EAU) + exploration rapide | Qwen-Image-Edit 2509 + LoRA Lightning 4 steps (édition), Z-Image-Turbo (exploration) |
| `ernie_turbo.json` | Génération image rapide (8 steps, cfg 1) avec enhancement de prompt par LLM local (toggle sur le nœud) | Ernie-Image Turbo + prompt-enhancer |
| `ernie_quality.json` | Génération image haute qualité (20 steps, cfg 4), même structure | Ernie-Image + prompt-enhancer |

Notes :
- Les prompts par défaut reprennent les exemples de la spec (`ai_content_studio_media_entertainment_gb10.md`) ; à adapter dans les nœuds `CLIPTextEncode`.
- `localized_assets.json` : charger l'asset maître dans le nœud `LoadImage`.
- Les sorties sont préfixées `campaign/`, `storyboard/`, `localized/` dans le dossier output de ComfyUI.
- Audio LTX 2.3 : généré conjointement à la vidéo depuis le prompt (l'audio VAE est dans le checkpoint — aucun modèle en plus). Dans l'app : case "Générer l'audio" pour les pipelines vidéo. Les workflows UI drag-drop l'incluent aussi : teaser de `campaign_generator.json` et chaîne FLF2V de `storyboard_animatic.json` (audio par segment + `AudioConcat`), testés en rendu avec piste audio vérifiée.
- Le pipeline Animatic (FLF2V) de l'app n'est proposé que dans le scénario Storyboard + Animatic.
- Encodeur texte des branches Flux2 Klein **9B** : `qwen_3_8b_fp8mixed` obligatoire (le `qwen_3_4b` des templates 4B produit un conditioning 7680-dim incompatible → erreur "mat1 and mat2 shapes cannot be multiplied").
- Tous les workflows ont été testés en rendu réel le 2026-07-06 (vidéos LTX testées en durée réduite ~2 s).
