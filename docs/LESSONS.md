# Leçons & pièges (durement acquis — lire avant de toucher aux graphes)

Chaque point ci-dessous a été découvert par un échec réel puis validé par un rendu GPU. Ne pas re-deviner : réutiliser.

## Modèles & appariements (installés sur ce GB10)

| Usage | Modèle | Encodeur / VAE | Réglages validés |
|---|---|---|---|
| Image qualité | `flux-2-klein-9b-fp8` (UNETLoader) | **`qwen_3_8b_fp8mixed`** type `flux2` + `flux2-vae` | 4 steps, cfg 1, euler, négatif = ConditioningZeroOut(positif), sigmas `Flux2Scheduler` |
| Image rapide + enrichisseur intégré | `ernie-image-turbo` | `ministral-3-3b` type flux2 + prompt-enhancer + `flux2-vae` | 8 steps cfg 1 (turbo) / 20 steps cfg 4 (base) |
| Exploration | `z_image_turbo_bf16` | `qwen_3_4b` + `ae` | 8 steps cfg 1 |
| Édition/localisation | `qwen_image_edit_2509_fp8_e4m3fn` | `qwen_2.5_vl_7b_fp8_scaled` + `qwen_image_vae` + LoRA `Qwen-Image-Edit-2509-Lightning-4steps` | 4 steps cfg 1 |
| Vidéo (+audio) | checkpoint `ltx-2.3-22b-dev-fp8` + LoRA `ltx_2.3_22b_distilled_1.1_lora_dynamic…` (0.5) | text encoder `gemma_3_12B_it_fp4_mixed` via `LTXAVTextEncoderLoader` | `SamplerEulerAncestral(eta 0)` + `ManualSigmas` "1.0, 0.99375, 0.9875, 0.98125, 0.975, 0.909375, 0.725, 0.421875, 0.0" (8 steps distillés), cfg 1, 25 fps |

**Piège n°1 — encodeur Flux2** : les templates officiels "klein" sont en 4B et référencent `qwen_3_4b`. Avec le 9B installé, ça produit un conditioning 7680-dim (3×2560) là où le modèle attend 12288 (3×4096) → `mat1 and mat2 shapes cannot be multiplied` dans `txt_in`. Toujours `qwen_3_8b_fp8mixed` avec le 9B.

**Piège n°2 — LoRA Qwen** : seul `Qwen-Image-Edit-2509-Lightning-4steps-V1.0-bf16` est installé (PAS `Qwen-Image-Lightning-4steps-V1.0`).

## Vidéo LTX 2.3

- **FLF2V (first/last frame)** par segment : `LTXVPreprocess(img_compression 35)` ×2 → `LTXVAddGuide(frame_idx 0, strength 0.7)` → `LTXVAddGuide(frame_idx -1, 0.7)` → sampler sur le latent AddGuide2[2] → **sortie sampler slot 1 (`denoised_output`)** → `LTXVCropGuides` (conditioning depuis AddGuide2) → `VAEDecodeTiled(768/64/4096/64)`.
- **Piège n°3 — recadrage sauvage** : `LTXVAddGuide` center-croppe/zoome toute image guide dont le ratio ≠ latent → résultat "sans rapport" avec l'image. Toujours insérer `ImageScale(lanczos, width, height, crop:"center")` avant `LTXVPreprocess`, et dériver le format vidéo de la 1ʳᵉ image (côté long ≤1280, multiples de 32).
- **Piège n°4 — prompt de mouvement** : en FLF2V le texte doit décrire le MOUVEMENT ; un prompt de contenu (ex. prompt de poster) fait dériver le milieu des segments vers ce contenu (effet "diaporama d'images inventées"). Segments courts (2–3 s) = fidélité ; longs (5 s+) = dérive.
- Frames valides : `8n+1` (ex. 49 ≈ 2 s @ 25 fps ; formule `8*round((s*25-1)/8)+1`).
- La hauteur/largeur est arrondie au multiple de 32 inférieur au rendu (720 → 704) : normal.
- **Audio** : AUCUN modèle supplémentaire requis — `LTXVAudioVAELoader(ckpt_name="ltx-2.3-22b-dev-fp8.safetensors")` charge l'audio VAE depuis le checkpoint (le "vocoder" listé par certains templates n'est pas nécessaire au chemin standard). Câblage : `LTXVEmptyLatentAudio(frames, 25, 1, audio_vae)` → `LTXVConcatAVLatent(video_latent, audio_latent)` AVANT le sampler → `LTXVSeparateAVLatent(sampler[1])` → slot 0 = vidéo (vers CropGuides/decode), slot 1 → `LTXVAudioVAEDecode` → `CreateVideo.audio` (entrée optionnelle). Multi-segments : chaîner les AUDIO avec `AudioConcat(direction:"after")`.
- Le template t2v officiel est en 2 passes (basse rés. + `LTXVLatentUpsampler` ×2, upscaler `ltx-2.3-spatial-upscaler-x2-1.1`) — réutiliser `workflows/api/ltx_t2v.json` plutôt que le recoder.
- **Piège n°5 — adhérence au prompt** : le pipeline distillé tourne à **cfg 1** (`CFGGuider`), donc pas de guidance classifier-free et negative prompt ignoré. L'adhérence repose sur le **prompt-enhancer intégré** du template officiel : `LoraLoader(gemma-3-12b-it-abliterated_lora_rank64_bf16, 1, 1)` sur l'encodeur → `TextGenerateLTX2Prompt(max_length 2048, sampling on, temp 0.7)` → texte enrichi vers le `CLIPTextEncode` positif (encodé avec le clip SANS LoRA ; la sortie model du LoraLoader est inutilisée). L'avoir omis = vidéos plates et prompts non respectés (constat utilisateur 2026-07-07). Présent dans : templates api t2v/i2v (`enrich:"builtin"` au manifest → gemma4 court-circuité), `addLtxEnhance` par segment FLF2V, et les workflows drag-drop `storyboard_animatic.json` (5 enhancers) / `campaign_generator.json` (teaser). Ne jamais le retirer d'un graphe LTX.

## API & graphes ComfyUI

- **Piège n°5 — slots `ComfyMathExpression`** : slot 0 = FLOAT, slot 1 = INT. Une entrée INT (ex. `length`) câblée sur le slot 0 → `return_type_mismatch`.
- **Piège n°6 — ids non numériques** : certains templates API contiennent des clés comme `"PH"`. Pour générer de nouveaux ids : `Math.max(0, ...keys.map(Number).filter(Number.isFinite)) + 1`.
- `ImageStitch(match_image_size:true)` étire l'image la plus petite : équilibrer les lignes d'une grille (4 → 2+2, 5 → 3+2) sinon une ligne courte devient géante.
- Format UI : links du graphe principal = tableaux `[id,src,slot,dst,slot,type]` ; dans `definitions.subgraphs` = dicts (`origin_id`/`target_id`) et les ids **-10/-20** sont les nœuds frontière entrée/sortie (pas des liens cassés). Types "virtuels" absents d'object_info mais valides : `MarkdownNote`, `Note`, `Reroute`.
- Ordre des `widgets_values` (format UI) : inputs widget du schéma dans l'ordre required+optional ; tout INT avec `control_after_generate:true` est suivi d'un widget parasite ("randomize"/"fixed") à ignorer. COMBO en deux styles (liste littérale vs `type:"COMBO"`+`extra.options`). Géré par `tools/convert.py`.
- Templates officiels de référence : dans le conteneur `comfyui-nvidia` sous `/comfy/mnt/venv/lib/python3.12/site-packages/comfyui_workflow_templates_media_{image,video,other}/templates/`. **Toujours partir d'eux** pour un nouveau modèle, jamais de mémoire.

## Application

- Les fetch de `manifest.json` et des templates utilisent `cache:"no-store"` — indispensable, sinon le navigateur sert des versions périmées après modification côté serveur.
- gemma4:e4b : appels `/api/chat` avec `format:"json"` + `think:false` (retry sans `think` si 4xx). Ses réponses JSON peuvent contenir des objets là où on attend des chaînes → toujours normaliser. Premier appel à froid ≈ 45 s (chargement du modèle).
- gpt-image-1 (OpenAI) et gemini-2.5-flash-image acceptent le CORS navigateur ; Higgsfield non (intégration via MCP côté agent uniquement).
- ComfyUI n'a pas d'API de suppression d'outputs → la "suppression" galerie est un masquage persistant (localStorage).
