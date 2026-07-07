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
| `"{{DURATION}}"` (s), `"{{FRAMES}}"` (= durée×fps+1, fps=25 par défaut) | nombres |

**manifest.json** (v2, deux sections) :
- `pipelines:[{id, label, scenario?, controls, defaults?, fps?}]` — pilote l'UI. `scenario` (chaîne ou liste) restreint le pipeline à un/des scénario(s) ; absent = disponible partout. `controls` = liste des champs de formulaire à afficher, parmi `duration, shots, hold, variants, ratio, audio, image, markets, seq` (mappés aux wraps par `CONTROL_WRAPS`). `defaults.duration` = valeur remise au changement de pipeline. `fps` propagé à `buildGraph` pour `{{FRAMES}}` (ex. Wan = 16). Un fallback JS (`PIPELINES_FALLBACK`) couvre les 7 pipelines de base si la section manque.
- `workflows:[{id, label, pipeline, model, file, enrich?, builder?, engine?, fps?}]`. `file:null` + `builder` = graphe construit en JS (dispatch via le registre `BUILDERS`). `enrich:"builtin"` (Ernie, templates LTX) court-circuite l'auto-enrichissement gemma. `engine:"ernie"` bascule les builders storyboard/campagne sur Ernie-Image.

## Flux Generate (handler du bouton)

1. Auto-enrichissement gemma optionnel (sauf `enrich:"builtin"`).
2. Calcul seed/ratio/batch/durée.
3. Si `wf.builder` : dispatch via le registre `BUILDERS` (`flf2v`→`generateSequence`, `storyboard_full`→`generateStoryboardFull` (gemma découpe le brief en N plans → `buildStoryboardFullGraph`), `campaign_full`→`generateCampaignFull`). Un nouveau builder = une fonction `(seed, width, height)` + une entrée dans `BUILDERS`.
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

## Ajouter un modèle / workflow (outillé)

`tools/onboard.py <workflow_ui.json> --id <id> --label "<label>" --pipeline <p> --model "<nom>" [--fps N] [--enrich builtin]` fait toute la chaîne : rafraîchit `object_info`, convertit le format UI en API (`convert.py`), **injecte les placeholders** (`{{PROMPT}}`/`{{NEGATIVE_PROMPT}}` sur les CLIPTextEncode positif/négatif — ou l'input `prompt` du `TextGenerateLTX2Prompt` s'il est sur le chemin —, `{{SEED}}`, `{{WIDTH}}/{{HEIGHT}}/{{BATCH}}` des `Empty*Latent*`, `{{FRAMES}}` des latents vidéo, `{{IMAGE}}` des `LoadImage`), vérifie les `.safetensors` sur disque, écrit `workflows/api/<id>.json`, ajoute l'entrée manifest, puis lance `validate.py --reduce`. Le workflow source vient soit de `workflows/*.json`, soit d'un template officiel du conteneur (`docker exec comfyui-nvidia cat …/templates/<x>.json`).

`tools/validate.py <api.json> [--reduce] [--frames 0,12,24] [--audio] [--image <fichier>]` : vérif structurelle (nœuds dans `object_info`, liens intègres, modèles sur disque) → substitution des placeholders par des valeurs de test → soumission → poll → extraction frames/mp3 pour inspection. **Toujours regarder le contenu produit**, pas seulement le statut (cf. `docs/TESTING.md`).

**Nouveau pipeline** (jeu de contrôles UI inédit) : ajouter une entrée à `pipelines[]` du manifest (`controls`, `scenario?`, `fps?`) — aucun JS à toucher si les contrôles existent déjà. **Nouveau builder JS** : une fonction `(seed, width, height)` + une entrée dans le registre `BUILDERS` + `{file:null, builder:"<nom>"}` au manifest.

### Monter un modèle en version supérieure
Ré-onboarder le template officiel de la nouvelle version sous un id suffixé (`_v2`) au lieu d'écraser : `onboard.py … --id <base>_v2`. Les deux apparaissent alors dans le menu Modèle → rendu **A/B côte à côte** dans la galerie (même brief/seed). Une fois la nouvelle version validée, retirer/renommer l'ancienne entrée manifest (le fichier api reste, réactivable en 1 ligne). Piège récurrent : un modèle plus gros exige souvent un autre encodeur (cf. Flux2 Klein 9B ⇒ `qwen_3_8b_fp8mixed`, LESSONS) — `onboard.py` détecte les fichiers manquants, `validate.py` attrape au rendu les incompatibilités de dimensions que la vérif structurelle laisse passer.
