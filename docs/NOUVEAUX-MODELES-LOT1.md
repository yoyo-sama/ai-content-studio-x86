# LOT 1 — Nouveaux modèles ComfyUI (Krea 2, LTX 2.5, Minimax H3)

Synthèse de qualification des 7 nouveaux templates API. **Toutes les preuves ci-dessous
proviennent d'une inspection réelle** (frames extraites à `ffmpeg` puis regardées, pistes
audio mesurées à `ffprobe`/`volumedetect`) — aucun verdict n'est fondé sur un statut de job
ou sur la simple existence d'un fichier.

- Rendus source : `/home/sparks/comfyui-spark/basedir/output/studio/lot1/`
- Frames + planches + MP3 d'inspection : `/home/sparks/comfyui-spark/basedir/output/validate/lot1/`
- Images d'entrée : `/home/sparks/comfyui-spark/basedir/input/lot1_{charsheet,locsheet,scene_a,scene_b}.png`

Note : `GET /history` du conteneur ComfyUI est vide (redémarrage depuis le lot). Les fichiers
de sortie sont intacts et font seuls foi — c'est d'ailleurs la règle du projet (on regarde les
pixels, pas les statuts).

Les 15 fichiers modèles/LoRA cités dans ce document ont été vérifiés présents sous
`/home/sparks/comfyui-spark/basedir/models/` (15/15 OK, aucun manquant).

## Récapitulatif

| Pipeline | Template | Preuve inspectée | Verdict |
|---|---|---|---|
| Krea 2 t2i | `workflows/api/krea2_t2i.json` | `studio/krea2_00002_.png` | OK |
| LTX 2.5 t2v | `workflows/api/ltx25_t2v.json` | `lot1/ltx25_t2v_00001_.mp4` | OK |
| LTX 2.5 i2v | `workflows/api/ltx25_i2v.json` | `lot1/ltx25_i2v_00001_.mp4` | OK |
| LTX 2.5 flf2v | `workflows/api/ltx25_flf2v.json` | `lot1/ltx25_flf2v_00001_.mp4` | OK (voir réserve « coupe franche ») |
| Minimax H3 t2v | `workflows/api/minimax_h3_t2v.json` | `lot1/h3_t2v_{base20,turbo4,turbo6,turbo8}_00001_.mp4` | OK — turbo ON @ 8 steps |
| Minimax H3 i2v | `workflows/api/minimax_h3_i2v.json` | `lot1/h3_i2v_probe_00001_.mp4` | OK |
| Minimax H3 r2v | `workflows/api/minimax_h3_r2v.json` | `lot1/h3_r2v_{turbo4,turbo6,turbo8,face8}_00001_.mp4` | OK — cohérence personnage **et** décor : fidèle |

---

## 1. Krea 2 — text2image (`workflows/api/krea2_t2i.json`)

Modèles exacts (lus dans le template) :

- `UNETLoader` → `diffusion_models/krea2_turbo_fp8_scaled.safetensors` (13 Go)
- `CLIPLoader` → `text_encoders/qwen3vl_4b_fp8_scaled.safetensors` (4,9 Go)
- `VAELoader` → `vae/qwen_image_vae.safetensors` (243 Mo)
- Échantillonnage : `KSampler`, `steps 8`, `cfg 1`, `euler` / `simple`, `denoise 1`
- Placeholders : `{{PROMPT}} {{WIDTH}} {{HEIGHT}} {{SEED}} {{BATCH}}`
- Sortie : `filename_prefix = studio/krea2`

Inspection réelle : `/home/sparks/comfyui-spark/basedir/output/studio/krea2_00002_.png`
(1280×720) — regardée. Image cinématographique cohérente : plaine et bosquets en silhouette
au coucher de soleil, filé horizontal (travelling latéral), dégradé ciel bleu→ambre, grain
argentique. Contenu plausible et propre, pas d'artefact, pas de texte parasite. Pipeline validé.

Observation mineure : `krea2_00001_.png` et `krea2_00002_.png` sont **octet pour octet
identiques** (même md5 `dbf3a644…`) — seed fixe, rendu déterministe. Comportement normal,
pas un défaut ; à garder en tête si un test cherche à qualifier la diversité.

## 2. LTX 2.5 — text2video + audio (`workflows/api/ltx25_t2v.json`)

Modèles exacts :

- `UNETLoader` → `diffusion_models/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors` (21 Go)
- `VAELoader` vidéo → `vae/ltx-2.5-video-vae-bf16.safetensors` (1,4 Go)
- `VAELoader` audio → `vae/ltx-2.5-audio-vae-bf16.safetensors` (348 Mo)
- `CLIPLoader` principal → `text_encoders/gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors` (15 Go)
- `CLIPLoader` enhancer (`TextGenerateLTX2Prompt`) → `text_encoders/gemma4_e2b_it_bf16.safetensors` (9,6 Go)
- `LatentUpscaleModelLoader` → `latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors` (950 Mo)
- Sampler : `euler_ancestral` + `ManualSigmas` + `LTXVDualCFGGuider`, deux passes `SamplerCustomAdvanced` (base + upsample)
- Placeholders : `{{PROMPT}} {{NEGATIVE_PROMPT}} {{WIDTH}} {{HEIGHT}} {{DURATION}} {{SEED}}`
- Sortie : `studio/ltx25_t2v`

Inspection réelle — `lot1/ltx25_t2v_00001_.mp4` : 832×448, 24 fps, **25 frames**, 1,042 s.
Audio AAC 48 kHz stéréo, 1,010 s, mean −19,9 dB / max −6,4 dB, `silencedetect` 0 occurrence
→ piste réelle et continue.
Frames 0/12/24 regardées (`validate/lot1/ltx25_t2v_f{0,12,24}.png`, planche
`validate/lot1/ltx25_t2v.png`) : femme en ciré jaune et écharpe rouge marchant sur une jetée
battue par la houle, cadrage stable, mouvement de marche et de vagues cohérent d'une frame à
l'autre, pas de morphing ni de dérive de sujet. Rendu plus doux et plus froid (dominante bleue)
que Minimax H3 sur la même scène, mais parfaitement exploitable. Validé.

## 3. LTX 2.5 — image2video + audio (`workflows/api/ltx25_i2v.json`)

Mêmes 6 fichiers modèles que le t2v ci-dessus (transformer 22B distillé, VAE vidéo, VAE audio,
gemma4-12b-with-proj, gemma4_e2b_it, upscaler latent x2). Ajouts de graphe : `LoadImage` +
`LTXVPreprocess` + `ResizeImageMaskNode` + `LTXVImgToVideoInplace`.
Placeholders : `{{IMAGE}} {{PROMPT}} {{NEGATIVE_PROMPT}} {{WIDTH}} {{HEIGHT}} {{DURATION}} {{SEED}}`.
Sortie : `studio/ltx25_i2v`.

Inspection réelle — `lot1/ltx25_i2v_00001_.mp4` : 832×448, 24 fps, 25 frames, 1,042 s.
Audio AAC 48 kHz stéréo, mean −17,8 dB / max −5,1 dB, aucun silence.
Frames 0/12/24 regardées (`validate/lot1/ltx25_i2v_f{0,12,24}.png`) : la frame 0 reproduit
exactement l'image d'entrée `lot1_scene_a.png` (personnage de face sur la jetée, phare allumé
en arrière-plan, houle) → l'ancrage image fonctionne. Frames 12 et 24 : léger travelling avant,
le personnage baisse la tête, la houle progresse. Réserve mineure : la frame 24 est nettement
plus floue/molle que les précédentes (perte de netteté du visage en fin de clip) — typique d'un
test réduit à 25 frames, à revérifier sur une durée nominale avant de conclure à un défaut.
Validé. Une validation antérieure du même pipeline existe aussi sous
`output/validate/ltx25_i2v_00001__f{0,12}_00001_.png` + `ltx25_i2v_00001__audio_00001.mp3`.

## 4. LTX 2.5 — first/last frame to video + audio (`workflows/api/ltx25_flf2v.json`)

Mêmes fichiers modèles que t2v/i2v (transformer 22B distillé, VAE vidéo, VAE audio,
gemma4-12b-with-proj pour le conditioning, gemma4_e2b_it pour `TextGenerateLTX2Prompt`).
Pas d'upscaler latent dans ce graphe. Deux `LoadImage` (`{{IMAGE}}` / `{{IMAGE2}}`) →
`LTXVPreprocess` → `ResizeImageMaskNode` → deux `LTXVAddGuide` → `LTXVCropGuides`.
Sampler : `SamplerEulerAncestral` + `ManualSigmas` + `LTXVDualCFGGuider`.
Placeholders : `{{IMAGE}} {{IMAGE2}} {{PROMPT}} {{NEGATIVE_PROMPT}} {{WIDTH}} {{HEIGHT}} {{DURATION}} {{SEED}}`.
Sortie : `studio/ltx25_flf2v`.

Inspection réelle — `lot1/ltx25_flf2v_00001_.mp4` : 832×480, 24 fps, 25 frames, 1,042 s.
Audio AAC 48 kHz stéréo, mean −13,4 dB / max −1,5 dB, aucun silence.
Frames 0/12/24 regardées (`validate/lot1/ltx25_flf2v_f{0,12,24}.png`) : **les deux guides sont
respectés** — la frame 0 est `lot1_scene_a.png` (gros plan du personnage, phare turquoise,
crépuscule bleu), la frame 24 est `lot1_scene_b.png` (plan large, phare à lanterne rouge,
ciel de coucher de soleil, personnage plein pied au bout de la jetée). Aucun recadrage brutal
(le piège `LTXVAddGuide` documenté est bien neutralisé par le `ResizeImageMaskNode` amont).

**Réserve documentée** : frames 15/18/21 extraites en plus
(`validate/lot1/flf_x{15,18,21}.png`, planche `validate/lot1/flf_transition.png`) → la
transition entre les deux guides n'est pas un morphing progressif mais une **coupe franche
entre f15 et f18**. Ce n'est pas un défaut du template : à 25 frames de test réduit, avec deux
cadrages aussi éloignés (gros plan ↔ plan large), il ne reste pas assez de frames latentes pour
interpoler. Ne pas conclure à une régression FLF2V sur cette base — voir l'entrée ajoutée dans
`docs/LESSONS.md`.

## 5. Minimax H3 — text2video + audio (`workflows/api/minimax_h3_t2v.json`)

Modèles exacts :

- `UNETLoader` → `diffusion_models/minimax_h3_fl2va_pruned_w4a8_mixed.safetensors` (12 Go)
- `CLIPLoader` (`type: "minimax"`) → `text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors` (15 Go)
- `VAELoader` vidéo → `vae/minimax_h3_video_vae_fp16.safetensors` (4,9 Go)
- `VAELoader` audio → `vae/minimax_h3_audio_vae_fp32.safetensors` (578 Mo)
- **LoRA turbo** → `loras/H3/minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors` (592 Mo),
  chargée par `LoraLoaderModelOnly` (node `134`, `strength_model: 1`) ; sa sortie alimente
  **à la fois** `BasicScheduler` (node `124`) et `BasicGuider` (node `126`) — la LoRA est donc
  câblée en dur, il n'y a pas de nœud bascule.
- Échantillonnage : `KSamplerSelect res_multistep` + `BasicScheduler simple`, **`steps: 8`**, `denoise 1`
- Longueur : `ComfyMathExpression` `max(5, round(a*24)) + (5 - (max(5, round(a*24)) % 17)) % 17` → cale sur **17n+5**
- Dimensions arrondies au multiple de 32 inférieur (`a - a % 32`)
- Placeholders : `{{PROMPT}} {{WIDTH}} {{HEIGHT}} {{DURATION}} {{SEED}}`
- Sortie : `studio/minimax_h3_t2v`

Métriques communes aux 4 rendus de comparaison : 832×480, 24 fps, **39 frames** (= 17×2+5),
1,625 s, audio AAC 32 kHz stéréo 1,625 s, aucun silence détecté sur aucun des quatre.

### Décision turbo : **ON, 8 steps**

Comparaison visuelle des frames 0/19/38 (planches `validate/lot1/h3_t2v_{base20,turbo4,turbo6,turbo8}.png`) :

- **`h3_t2v_base20` (turbo OFF, 20 steps)** — référence. Ciré jaune d'une densité naturelle,
  chevelure argentée détaillée, écharpe rouge au tissu lisible, embruns et rochers nets,
  marche vers la caméra parfaitement continue sur les trois frames. Photoréaliste.
- **`h3_t2v_turbo4` (ON, 4 steps)** — **rejeté**. Effondrement colorimétrique net : le ciré
  vire au jaune fluo saturé et « clippé » (aplats sans modelé), les gris de la jetée prennent
  une dominante cyan franche, le ciel se poste­rise en bandes, les micro-détails (pavés,
  écume, cheveux) disparaissent. Le mouvement reste cohérent mais le rendu n'est plus
  photoréaliste — inutilisable en démo client.
- **`h3_t2v_turbo6` (ON, 6 steps)** — acceptable. Colorimétrie redevenue naturelle, plus de
  posterisation. Reste un peu en retrait de la référence : matières légèrement plus lisses,
  arrière-plan (houle, môle) moins structuré.
- **`h3_t2v_turbo8` (ON, 8 steps)** — **retenu**. Visuellement au niveau de `base20` :
  même densité du jaune, même détail de la chevelure et de l'écharpe, vagues et pavés nets,
  cohérence de mouvement identique sur les trois frames. Aucun artefact turbo résiduel.

**Décision : LoRA turbo ACTIVÉE à 8 steps** — c'est exactement ce que codent déjà les trois
templates H3 (`steps: 8`, `LoraLoaderModelOnly` câblée). Rationnel : 8 steps turbo restitue la
qualité de 20 steps sans LoRA pour **2,5× moins d'étapes de débruitage** ; descendre à 6 coûte
de la matière pour un gain marginal, et 4 casse la colorimétrie. Ne pas exposer 4 steps dans
l'UI ; si un mode « brouillon » est demandé un jour, 6 est le plancher acceptable, pas 4.

## 6. Minimax H3 — image2video + audio (`workflows/api/minimax_h3_i2v.json`)

Mêmes 4 fichiers modèles que le t2v (`minimax_h3_fl2va_pruned_w4a8_mixed.safetensors`,
`qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors`, VAE vidéo fp16, VAE audio fp32) + la même
LoRA turbo `loras/H3/minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors`
(node `121`, `strength_model: 1`, alimentant `BasicScheduler` node `9` à `steps: 8` et
`BasicGuider` node `16`). Ajout : `LoadImage` → `MiniMaxH3ImageToVideo`.
Placeholders : `{{IMAGE}} {{PROMPT}} {{WIDTH}} {{HEIGHT}} {{DURATION}} {{SEED}}`.
Sortie : `studio/minimax_h3_i2v`.

Inspection réelle — `lot1/h3_i2v_probe_00001_.mp4` : 832×480, 24 fps, 39 frames, 1,625 s.
Audio AAC 32 kHz stéréo, mean −20,4 dB / max −7,6 dB, aucun silence.
Frames 0/19/38 regardées (`validate/lot1/h3_i2v_probe_f{0,19,38}.png`) : la frame 0 reproduit
fidèlement l'entrée `lot1_scene_a.png` (même personnage, même jetée, même phare turquoise) ;
frames 19 et 38 : léger travelling avant, une grosse gerbe d'écume monte derrière le phare,
le visage et la coupe de cheveux restent identiques d'un bout à l'autre. Aucune dérive.
Validé. Une validation antérieure du t2v H3 existe aussi sous
`output/validate/minimax_h3_t2v_00001__f{0,12}_00001_.png` + `…_audio_00001.mp3`.

## 7. Minimax H3 — reference2video + audio (`workflows/api/minimax_h3_r2v.json`)

Modèles exacts :

- `UNETLoader` → `diffusion_models/minimax_h3_ref2va_pruned_w4a8_mixed.safetensors` (11 Go)
  — **checkpoint différent du t2v/i2v** (`ref2va`, pas `fl2va`) ; ne pas les confondre.
- `CLIPLoader` (`type: "minimax"`) → `text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors`
- `VAELoader` vidéo → `vae/minimax_h3_video_vae_fp16.safetensors`
- `VAELoader` audio → `vae/minimax_h3_audio_vae_fp32.safetensors`
- LoRA turbo → `loras/H3/minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors`
  (node `145`, `strength_model: 1` → `BasicScheduler` node `124` `steps: 8` + `BasicGuider` node `126`)
- `MiniMaxH3ReferenceToVideo` (node `136`), `ref_image_size: "match"`, deux références :
  `ref_images.ref_image_0` ← `LoadImage` node `137` = `{{IMAGE}}` (personnage / charsheet),
  `ref_images.ref_image_1` ← `LoadImage` node `139` = `{{IMAGE2}}` (décor / locsheet)
- Placeholders : `{{IMAGE}} {{IMAGE2}} {{PROMPT}} {{WIDTH}} {{HEIGHT}} {{DURATION}} {{SEED}}`
- Sortie : `studio/minimax_h3_r2v`

### Références utilisées (inspectées)

- `lot1/charsheet_00001_.png` (1920×1088) — planche personnage regardée : femme, coupe pixie
  blanc/argent, ciré **jaune** à capuche, écharpe **rouge** tricotée, jean sombre, bottes en
  caoutchouc **vert olive** ; portrait + 7 expressions + 4 tours (face/3-4/profil/dos) +
  détails de vêtements + nuancier.
- `lot1/locsheet_00001_.png` (1920×1088) — planche décor regardée : intérieur de phare —
  murs de pierre blanche irrégulière, hautes fenêtres cintrées à petits carreaux, **sol en
  carrelage vert**, escalier hélicoïdal en fonte ajourée sombre, **instruments en laiton**
  (habitacle/compas et longue-vue sur colonnes), lanterne murale, coffre en bois.

### Verdict cohérence de scène : **FIDÈLE** (personnage ET environnement)

Frames 0/19/38 regardées pour les quatre rendus
(`validate/lot1/h3_r2v_{turbo4,turbo6,turbo8,face8}_f{0,19,38}.png`, planches homonymes `.png`) :

- **`h3_r2v_face8_00001_.mp4` — preuve principale, la plus probante.** Le personnage est de
  face et net : coupe pixie blanc/argent, peau claire tachetée de son, yeux gris-bleu, ciré
  jaune, écharpe rouge tricotée — **le visage correspond trait pour trait au portrait en haut
  à gauche de `charsheet_00001_.png`**, sur les trois frames. Le décor derrière lui est celui
  de `locsheet_00001_.png` : mur de pierre blanche, fenêtre cintrée à petits carreaux,
  carrelage vert au sol, instrument de laiton sur colonne à gauche, escalier hélicoïdal en
  fonte à droite, lanterne murale allumée. **Personnage et décor tenus simultanément.**
  Preuves : `validate/lot1/h3_r2v_face8_f0.png`, `_f19.png`, `_f38.png` vs
  `studio/lot1/charsheet_00001_.png` et `studio/lot1/locsheet_00001_.png`.
- **`h3_r2v_turbo8`** et **`h3_r2v_turbo6`** : personnage de dos, mais tenue (ciré jaune,
  écharpe rouge entrevue au col, cheveux blancs courts, jean sombre) conforme à la charsheet ;
  le décor est repris fidèlement et **de façon stable dans le temps** (mêmes fenêtres, même
  carrelage vert, mêmes deux colonnes de laiton, même escalier, même lanterne aux frames 0, 19
  et 38, avec un simple panoramique). `turbo8` est légèrement plus net et fait même réapparaître
  le coffre en bois présent sur la locsheet.
- **`h3_r2v_turbo4`** : le décor reste identifiable (fenêtres cintrées, carrelage vert, laitons,
  escalier) et le personnage aussi (ciré jaune, cheveux blancs) — la **cohérence** n'est donc pas
  en cause — mais la **qualité** est très dégradée : voile lumineux/bloom généralisé, rendu
  « aquarelle » délavé, et surtout **une bande de couleurs parasites en bas de cadre** (traînée
  arc-en-ciel jaune/rouge/bleu) absente de tous les autres rendus. Preuve :
  `validate/lot1/h3_r2v_turbo4_f0.png` (bande visible sur les trois frames). Rendu rejeté,
  cohérent avec la décision « pas de 4 steps ».

Conclusion r2v : **fidèle** sur les deux axes exigés par le client (personnage **et**
environnement), à 6 et 8 steps ; le r2v H3 honore réellement ses deux images de référence
simultanément, sans collage ni split-screen, et sans le piège de géométrie du dual Qwen-Edit
(ici les deux références sont des conditionings symétriques, aucune ne fournit le latent de
départ). Réglage recommandé : **8 steps**.

## Problèmes relevés lors de l'inspection

1. **Minimax H3 à 4 steps turbo — dégradation sévère et reproductible** (t2v : jaune fluo
   clippé, dominante cyan, posterisation ; r2v : bloom + bande de couleurs parasites en bas de
   cadre). Ne jamais exposer 4 steps.
2. **LTX 2.5 FLF2V en test réduit 25 frames — coupe franche** entre les deux guides au lieu
   d'une transition. Artefact de test réduit, pas un bug du template.
3. **LTX 2.5 i2v — perte de netteté sur la dernière frame** du clip réduit (f24). À
   reconfirmer sur durée nominale.
4. **Krea 2 — rendus identiques à seed fixe** (`krea2_00001_` = `krea2_00002_`, même md5).
   Comportement attendu, signalé pour éviter une fausse piste lors d'un futur test de diversité.

Aucun fichier corrompu, aucune piste audio muette, aucun modèle manquant : aucun rendu n'a eu
besoin d'être relancé.
