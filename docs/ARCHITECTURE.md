# Architecture

## Vue d'ensemble

```
Navigateur ── index.html (nginx :8090, statique)
   │  fetch/WS
   ├── ComfyUI :8188      REST /prompt /history /queue /view /upload/image /object_info /models/*
   │                      WS /ws?clientId=…  (progress, executed, execution_success/error)
   ├── Ollama :11434      /api/chat (gemma4:e4b : enrichissement + découpage en plans)
   └── APIs cloud (opt.)  OpenAI gpt-image-1, Gemini gemini-2.5-flash-image (clé en sessionStorage)
```

Tout est côté client. Les graphes ComfyUI sont soit des **templates API substitués**, soit **construits dynamiquement en JS**, puis POSTés à `/prompt`. Le suivi se fait par WebSocket (jobs, assets) avec relecture d'`/history` en fin de job (`collectHistory`) pour les sorties que le WS ne remonte pas et pour l'extraction des prompts.

## Formats de workflows

**Format UI** (`workflows/*.json`) : graphes complets exportés ComfyUI (`nodes`/`links`/`widgets_values`, éventuellement `definitions.subgraphs`). Usage : drag-drop dans l'interface ComfyUI. Non consommables par `/prompt` directement → `tools/convert.py` les convertit en API.

**Format API** (`workflows/api/*.json` et builders JS) : `{ "<id>": { "class_type", "inputs": { nom: valeur | [refId, slot] } } }`. Les templates de `api/` contiennent des placeholders substitués textuellement par `buildGraph()` :

| Placeholder | Remplacé par |
|---|---|
| `"{{PROMPT}}"`, `"{{NEGATIVE_PROMPT}}"`, `"{{IMAGE}}"` | chaînes JSON |
| `"{{SEED}}"`, `"{{WIDTH}}"`, `"{{HEIGHT}}"`, `"{{BATCH}}"` | nombres |
| `"{{DURATION}}"` (s), `"{{FRAMES}}"` (= durée×25+1) | nombres |

**manifest.json** : `{workflows:[{id, label, pipeline, model, file, enrich?, builder?}]}`. `file:null` + `builder` = pipeline construit en JS. `pipeline` ∈ text2image / image2image / text2video / image2video / sequence2video / storyboard_full / campaign_full. `enrich:"builtin"` (Ernie) court-circuite l'auto-enrichissement gemma.

## Flux Generate (handler du bouton)

1. Auto-enrichissement gemma optionnel (sauf `enrich:"builtin"`).
2. Calcul seed/ratio/batch/durée.
3. Branches spéciales : `sequence2video` → `generateSequence` ; `storyboard_full` → `generateStoryboardFull` (gemma découpe le brief en N plans → `buildStoryboardFullGraph`) ; `campaign_full` → `generateCampaignFull`.
4. Sinon : boucle `jobsSpec` (1 entrée, ou 1/marché sélectionné en image2image) → `tryCloudGeneration` (modes hybride/cloud, images seulement) sinon template local + `applyLtxAudio` éventuel → POST → `trackJob`.

## Builders de graphes JS (le cœur du projet)

- `makeGraphBuilder()` → `{g, add}` ; ids séquentiels "1"…
- `addFluxShared/addFluxShot` : branche image Flux2 Klein 9B (4 steps, cfg 1, négatif = `ConditioningZeroOut` du positif, sigmas via `Flux2Scheduler`).
- `addErnieShared/addErnieShot` : branche image Ernie-Image base (`KSampler` 20 steps, cfg 4, euler/simple, encodeur ministral-3-3b type flux2, VAE flux2) — variantes `storyboard_full` et `campaign_full` sélectionnées via `engine: "ernie"` dans le manifest, images plus cohérentes/fidèles au brief que Flux2 (mais 20 steps vs 4).
- `addLtxShared` : checkpoint LTX 2.3 dev-fp8 + text encoder gemma_3_12B + LoRA distillée (0.5) + `SamplerEulerAncestral(eta 0)` + `ManualSigmas` 8 steps (`FLF2V_SIGMAS`) + audio VAE optionnel + LoRA d'enhancer sur le clip (`enh`).
- `addLtxEnhance(add, sh, prompt, seed)` : prompt-enhancer intégré LTX (`TextGenerateLTX2Prompt` sur le clip LoRA-isé) — indispensable car le distillé tourne à cfg 1 (voir LESSONS piège n°5) ; appliqué à chaque segment FLF2V et présent dans les templates api t2v/i2v (`enrich:"builtin"`).
- `addFLF2VChain` : segments first/last-frame (2×`LTXVPreprocess` → 2×`LTXVAddGuide` frame_idx 0/-1 strength 0.7 → sampler → `LTXVCropGuides` → `VAEDecodeTiled`), audio joint optionnel par segment, concat images `ImageBatch` + audio `AudioConcat`. `buildStoryboardFullGraph` ajoute une **tenue du plan final** (champ `holdDuration`, 0 = off) : segment supplémentaire dernière→dernière image, caméra verrouillée.
- `addGrid` : contact-sheet `ImageStitch`, lignes équilibrées (`cols = ceil(n/ceil(n/3))`).
- `applyLtxAudio(graph)` : ajoute l'audio à un graphe API LTX existant — si `LTXVSeparateAVLatent` présent (t2v 2-passes) il ne manque que `LTXVAudioVAEDecode`+branchement ; sinon (i2v) enveloppe le sampler (`LTXVEmptyLatentAudio`+`LTXVConcatAVLatent` avant, `LTXVSeparateAVLatent` après, re-câblage des consommateurs).
- `mergeGraph(g, other, prefix)` : fusion de graphes API par préfixage des ids (utilisé pour insérer le teaser t2v dans la campagne complète).

## Galerie

Onglets Images/Vidéos avec compteurs. `addAsset` (dédoublonnage `seenAssets`, masquage persistant `deletedAssets` en localStorage, filtre des fichiers audio seuls) → `addAssetCard` → `groupFor` regroupe `studio/story*` et `studio/campaign*` en encadrés par dossier. Lightbox intégré (images+vidéos) avec **copie du prompt** : `recordPrompts(entry)` remonte le graphe d'un job depuis chaque nœud de sortie (`promptForNode`, texte `CLIPTextEncode` le plus long = positif) et remplit `assetPrompts`. Actions cartes : agrandir/lire, utiliser en entrée (i2i/i2v — re-upload via `/view`→`/upload/image`), ➕ séquence (bascule scénario Storyboard + pipeline FLF2V), supprimer.

## i18n & thème

- i18n : dictionnaire `I18N` (clé = texte DOM d'origine) appliqué par `translateTree` (TreeWalker, `__orig` mémorisé par nœud texte) + `DYN_I18N` pour les chaînes à paramètres. Ajouter une chaîne = l'écrire en français dans le DOM + une entrée I18N.
- Thème : variables CSS dans `:root`, overrides `:root[data-theme="dark"]`. **Ne jamais coder une couleur en dur dans un composant** — passer par les variables (`--card`, `--bg-light`, …).

## Stockage navigateur

| Clé | Store | Contenu |
|---|---|---|
| `theme`, `lang`, `cloudMode`, `cloudPlatform` | localStorage | préférences |
| `deletedAssets` | localStorage | clés d'assets masqués |
| `cloudKey:<plateforme>` | **sessionStorage** | clés API (jamais persistées) |
