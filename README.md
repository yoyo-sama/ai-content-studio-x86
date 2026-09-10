🇫🇷 [Lire en français](README.fr.md)

# AI Content Studio — x86_64 / dedicated NVIDIA GPU fork

This repository is a fork of [`dellaicontent`](https://github.com/dell/dellaicontent), which
targets the Dell Pro Max GB10 / DGX Spark (ARM64, unified SoC memory). **This fork adapts the
same stack for a standard x86_64 workstation with a dedicated discrete NVIDIA GPU** — most
notably, it replaces the GB10-specific `mmartial/comfyui-nvidia-docker` image with **official
ComfyUI** (built locally from [`comfyanonymous/ComfyUI`](https://github.com/comfyanonymous/ComfyUI)),
and ships three installation paths: **Ubuntu 24.04** and **Omarchy** (Arch-based, Hyprland),
both Docker-based, and **Windows 10/11** (native, no Docker, dedicated NVIDIA GPU).

**Current version: 1.0.5** — see `TOUR-DE-CONTROLE-CHANGELOG.md` for the change history.

**Fully local** AI creative studio: image generation (Krea 2, Qwen-Edit) and video generation with audio (LTX 2.5, Minimax H3) via ComfyUI on a dedicated NVIDIA GPU, with prompt enrichment by a local LLM (Ollama). The application is served by nginx, with no build step and no framework (aside from a small `updater` backend service that handles in-app updates — see below) — two static modes to choose from: the `index.html` form (guided scenarios, see below) and the `canvas.html` node editor (see dedicated section below).

## Deployment (clone & run)

### Prerequisites

- **x86_64** Linux machine with a **dedicated NVIDIA GPU**, the proprietary driver installed,
  and [`nvidia-container-toolkit`](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) configured for Docker.
- **Docker** + **Docker Compose** (the `docker compose` plugin).
- See `docs/INSTALL-X86.md` for exact per-distro prerequisite commands.
- **Windows 10/11**: different (lighter) prerequisites — no Docker, no WSL2, just an
  up-to-date NVIDIA driver. See the Windows command below and `docs/INSTALL-X86.md`.

### Automatic installation (recommended)

Pick the script matching your distro:

```bash
git clone <url-du-repo> ~/ai-content-studio
cd ~/ai-content-studio
./install-ubuntu.sh      # Ubuntu 24.04
# or
./install-omarchy.sh     # Omarchy (Arch-based)
```

> **Something not working, or a machine where a previous install was attempted?**
> → **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** — symptom → cause table, diagnosis
> in three commands, step-by-step reinstall on an already-installed machine, and clean reset.

Both scripts share the same application logic (`scripts/lib-install-common.sh`) and only
differ in how they check/report distro-specific system prerequisites (`apt`/`pacman`). They do
everything in a single command, **idempotently** (safe to re-run):

1. Checks the environment (architecture, `docker`/`docker compose`, NVIDIA driver/toolkit —
   distro-specific package names/commands are printed if something is missing, not installed
   automatically).
2. Detects the 3 services (web app `:8090`, ComfyUI `:8188`, Ollama `:11434`) **by actual
   role** (HTTP health check), not by container name — reuses anything already running,
   **including an Ollama installed natively (systemd), which is not a container**, and never
   recreates/destroys a service it doesn't own (checked via docker-compose labels). Whatever
   is missing is created in its own stack at the root of the home directory (`~/comfyui`,
   `~/ollama`) from the `docker/stacks/*.yml` templates, with their folders created as the
   user BEFORE the containers. A service that is **installed but stopped** is restarted rather
   than duplicated: a stopped container is started again (`docker start`), a native Ollama
   (systemd) is started via `sudo -n systemctl start ollama` — never blocking on a password
   prompt: if passwordless sudo is not available, the script prints the command to run and
   creates nothing. If a port is held by a service that cannot be restarted, nothing is created
   either, instead of letting Docker fail on "port is already allocated".
3. Downloads the models listed in `scripts/models.txt` that are missing, into
   `~/comfyui/models/<folder>/` (automatically skipped if the file is already present
   with the correct size — no unnecessary re-downloading).
4. Pulls the `gemma4:e4b` Ollama model if it's missing, **through the HTTP API**
   (`POST /api/pull`) rather than `docker exec`: same behaviour whether Ollama runs in our
   container, in someone else's, or natively.
5. Waits for ComfyUI to answer on `:8188` when it has just been created, then displays a final
   summary (service status, actual locations, models, health checks).

The scripts' output and code comments are in English.

**`HF_TOKEN` (Hugging Face token, optional but required for LTX 2.5)**: the 4 LTX 2.5 model
files come from a **"gated"** (access-restricted) Hugging Face repository — an anonymous
download fails with a 401 until you've accepted the model's terms. To get them:

1. Create an account on [huggingface.co](https://huggingface.co/) if you don't have one.
2. Accept the access terms on the model page:
   [huggingface.co/Lightricks/LTX-2.5](https://huggingface.co/Lightricks/LTX-2.5).
3. Generate an access token in your HF account settings (Settings → Access Tokens).
4. Re-run the installation with the token as an environment variable:

```bash
HF_TOKEN=<votre_jeton> ./install-ubuntu.sh   # or ./install-omarchy.sh
```

Without `HF_TOKEN`, the other models (Krea 2, Qwen-Edit, Minimax H3) download normally — only
the 4 LTX 2.5 files fail cleanly and are reported in the final summary, without blocking the
rest of the installation.

#### Windows 10/11 (native, no Docker)

For a Windows 10/11 x86_64 workstation with a dedicated NVIDIA GPU, use `install-windows.ps1`
instead — a standalone script (doesn't share `scripts/lib-install-common.sh` with the Linux
scripts), 100% native: no Docker, no WSL2.

```powershell
git clone <url-du-repo> ai-content-studio
cd ai-content-studio
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
```

`-ExecutionPolicy Bypass` is required: without it, PowerShell refuses by default to run a
freshly cloned script. The only prerequisite is an up-to-date proprietary NVIDIA driver — no
Docker, no WSL2, no pre-installed Python, no pre-installed 7-Zip (the script downloads its own
minimal extractor, `7zr.exe`), no Visual Studio Build Tools (`comfy_kitchen` installs from a
precompiled PyPI wheel, no compilation needed). PowerShell 5.1 and `curl.exe` both ship
natively with Windows 10 (1803+) and Windows 11.

`install-windows.ps1` does everything in a single command, in 7 steps, **idempotently** (safe
to re-run — nothing already present and valid is re-downloaded or recreated):

1. Checks for an NVIDIA GPU (`nvidia-smi`) — warns without blocking if it's absent.
2. Downloads/extracts the official ComfyUI portable build (NVIDIA build, ~2 GB, from the
   latest GitHub release) if not already present.
3. Installs `comfy_kitchen` best-effort (optional acceleration, never blocks).
4. Downloads the models listed in `scripts/models.txt` (idempotent, skipped if already
   present at the correct size).
5. Detects Ollama intelligently: already running → left untouched; installed but stopped →
   started automatically; not installed at all → guided to the official installer, nothing
   installed in its place.
6. Starts ComfyUI and the web server.
7. Displays a final summary with health checks.

`scripts/serve-windows.ps1` replaces nginx with a native PowerShell web server
(`System.Net.HttpListener`) that serves the static files and reverse-proxies `/comfy/*` to
ComfyUI and `/ollama/*` to Ollama — required because the frontend calls these APIs through
relative paths. It's started automatically by `install-windows.ps1`; no need to launch it by
hand.

`HF_TOKEN` (see above) works the same way on Windows:

```powershell
$env:HF_TOKEN = "<votre_jeton>"; powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
```

**Known limitations**:

1. No automatic in-app update on Windows — the Docker `updater` service isn't ported to this
   variant. Update manually with `git pull` in the repo folder.
2. The web server (`:8090`) listens on `localhost` only by default — accessible from this
   machine alone, not from the local network (unlike the Linux/Docker variant, which listens
   on all interfaces). `scripts/serve-windows.ps1` has the exact command to open LAN access
   (`netsh http add urlacl` + a firewall rule, run as administrator) in a comment, if needed.
3. The ComfyUI job progress bar isn't animated in real time (the WebSocket isn't proxied —
   purely cosmetic, generation and completion detection work normally).

### Manual installation / troubleshooting

For anyone who prefers to understand each step, doesn't have a full internet connection to
download everything at once, or wants to audit what the install scripts automate:

```bash
git clone <url-du-repo> ~/ai-content-studio
cd ~/ai-content-studio
docker compose up -d                              # app only (nginx :8090 + updater)
docker compose -f ~/comfyui/compose.yaml up -d    # ComfyUI (:8188)
docker compose -f ~/ollama/compose.yaml up -d     # Ollama  (:11434), skip if installed natively
```

Three separate stacks, one per service, each at the root of the home directory:

| Folder | Container | Image | Port | Role |
|---|---|---|---|---|
| `~/ai-content-studio` | `ai-content-studio-web` + `ai-content-studio-updater` | `nginx:alpine` | 8090 | Serves `index.html`/`canvas.html` + reverse-proxies to ComfyUI/Ollama |
| `~/comfyui` | `comfyui-nvidia` | built locally from `docker/comfyui-official/Dockerfile` (official [`comfyanonymous/ComfyUI`](https://github.com/comfyanonymous/ComfyUI)), tagged `ai-content-studio-comfyui:local` | 8188 | Image/video generation engine |
| `~/ollama` | `ollama-api` | `ollama/ollama:latest` | 11434 | Local LLM for prompt enrichment |

The install scripts create the two sibling stacks from the `docker/stacks/*.yml` templates,
and create their folders **before** the containers: a bind-mount whose source does not exist
yet is created by Docker as `root`, which locks the folder and makes every subsequent model
download fail. ComfyUI models live in `~/comfyui/models/`, Ollama weights in `~/ollama/data/`.

**Ollama installed natively** (the usual case on Ubuntu, `curl -fsSL https://ollama.com/install.sh | sh`)
is detected and reused as is — no container is created, and the required model is pulled
through the Ollama HTTP API. If the native service is installed but stopped, the script says
so and creates nothing, rather than starting a second Ollama that would fight for port 11434.

```bash
curl -X POST http://localhost:11434/api/pull -d '{"model":"gemma4:e4b"}'   # manual pull, container or native
```

**Important: model weights are NOT in the Git repository** (several dozen GB in total) —
download them manually into `~/comfyui/models/<folder>/` according to the table below
(same URLs as `scripts/models.txt`, used by the install scripts), before running a generation.
For LTX 2.5, see the `HF_TOKEN` section above (gated repository).

### Post-startup health checks

```bash
curl http://localhost:8090/                    # static app
curl http://localhost:8188/system_stats         # ComfyUI alive
curl http://localhost:11434/api/version          # Ollama alive
```

### Models to download

Each file goes into `~/comfyui/models/<folder>/` (ComfyUI stack path; adjust if you
changed the volume mapping). `install-ubuntu.sh`/`install-omarchy.sh` automatically download
the 19 files below from `scripts/models.txt` (source of truth — same URLs, same order); the
manual list that follows is equivalent for anyone who prefers `curl`/a browser.

#### Current pipelines (Krea 2, Qwen-Edit, LTX 2.5, Minimax H3)

19 files, URLs verified via an actual HTTP request against Hugging Face (`resolve/main/...`,
exact sizes in bytes in `scripts/models.txt`).

| Model / pipeline | File | Target folder | Size | URL |
|---|---|---|---|---|
| Qwen-Edit | `qwen_image_edit_2509_fp8_e4m3fn.safetensors` | `diffusion_models/` | 19 GB | [resolve/main](https://huggingface.co/Comfy-Org/Qwen-Image-Edit_ComfyUI/resolve/main/split_files/diffusion_models/qwen_image_edit_2509_fp8_e4m3fn.safetensors) |
| Qwen-Edit (encoder) | `qwen_2.5_vl_7b_fp8_scaled.safetensors` | `text_encoders/` | 8.7 GB | [resolve/main](https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors) |
| Qwen-Edit (VAE, shared with Krea 2) | `qwen_image_vae.safetensors` | `vae/` | 243 MB | [resolve/main](https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors) |
| Qwen-Edit (Lightning 4-step LoRA) | `Qwen-Image-Edit-2509-Lightning-4steps-V1.0-bf16.safetensors` | `loras/` | 810 MB | [resolve/main](https://huggingface.co/lightx2v/Qwen-Image-Lightning/resolve/main/Qwen-Image-Edit-2509/Qwen-Image-Edit-2509-Lightning-4steps-V1.0-bf16.safetensors) |
| Krea 2 (transformer) | `krea2_turbo_fp8_scaled.safetensors` | `diffusion_models/` | 13 GB | [resolve/main](https://huggingface.co/Comfy-Org/Krea-2/resolve/main/diffusion_models/krea2_turbo_fp8_scaled.safetensors) |
| Krea 2 (encoder) | `qwen3vl_4b_fp8_scaled.safetensors` | `text_encoders/` | 4.9 GB | [resolve/main](https://huggingface.co/Comfy-Org/Krea-2/resolve/main/text_encoders/qwen3vl_4b_fp8_scaled.safetensors) |
| Krea 2 (VAE, shared with Qwen-Edit) | `qwen_image_vae.safetensors` | `vae/` | 243 MB | [resolve/main](https://huggingface.co/Comfy-Org/Krea-2/resolve/main/vae/qwen_image_vae.safetensors) |
| LTX 2.5 (distilled transformer) ⚠️ gated | `ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors` | `diffusion_models/` | 21 GB | [resolve/main](https://huggingface.co/Lightricks/LTX-2.5/resolve/main/diffusion_models/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors) |
| LTX 2.5 (video VAE) ⚠️ gated | `ltx-2.5-video-vae-bf16.safetensors` | `vae/` | 1.4 GB | [resolve/main](https://huggingface.co/Lightricks/LTX-2.5/resolve/main/vae/ltx-2.5-video-vae-bf16.safetensors) |
| LTX 2.5 (audio VAE) ⚠️ gated | `ltx-2.5-audio-vae-bf16.safetensors` | `vae/` | 348 MB | [resolve/main](https://huggingface.co/Lightricks/LTX-2.5/resolve/main/vae/ltx-2.5-audio-vae-bf16.safetensors) |
| LTX 2.5 (main encoder) ⚠️ gated | `gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors` | `text_encoders/` | 15 GB | [resolve/main](https://huggingface.co/Lightricks/LTX-2.5/resolve/main/text_encoders/gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors) |
| LTX 2.5 (prompt-enhancer encoder) | `gemma4_e2b_it_bf16.safetensors` | `text_encoders/` | 9.6 GB | [resolve/main](https://huggingface.co/Comfy-Org/gemma-4/resolve/main/text_encoders/gemma4_e2b_it_bf16.safetensors) |
| LTX 2.5 (x2 latent upscaler, t2v/i2v only) ⚠️ gated | `ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors` | `latent_upscale_models/` | 950 MB | [resolve/main](https://huggingface.co/Lightricks/LTX-2.5/resolve/main/latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors) |
| Minimax H3 t2v/i2v (transformer) ⚠️ community reupload | `minimax_h3_fl2va_pruned_w4a8_mixed.safetensors` | `diffusion_models/` | 12 GB | [resolve/main](https://huggingface.co/AX1Y2JP/MiniMax-H3-W4A8-ConvRot/resolve/main/minimax_h3_fl2va_pruned_w4a8_mixed.safetensors) |
| Minimax H3 r2v (transformer, different checkpoint) ⚠️ community reupload | `minimax_h3_ref2va_pruned_w4a8_mixed.safetensors` | `diffusion_models/` | 11 GB | [resolve/main](https://huggingface.co/AX1Y2JP/MiniMax-H3-W4A8-ConvRot/resolve/main/minimax_h3_ref2va_pruned_w4a8_mixed.safetensors) |
| Minimax H3 (encoder) | `qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors` | `text_encoders/` | 15 GB | [resolve/main](https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors) |
| Minimax H3 (video VAE) | `minimax_h3_video_vae_fp16.safetensors` | `vae/` | 4.9 GB | [resolve/main](https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_video_vae_fp16.safetensors) |
| Minimax H3 (audio VAE) | `minimax_h3_audio_vae_fp32.safetensors` | `vae/` | 578 MB | [resolve/main](https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_audio_vae_fp32.safetensors) |
| Minimax H3 (turbo LoRA, t2v/i2v/r2v) ⚠️ community reupload | `minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors` | `loras/H3/` | 592 MB | [resolve/main](https://huggingface.co/koongrizzly/MiniMax_H3_int4_W4A8_ConvRot_Pruned/resolve/main/loras/minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors) |
| Minimax H3 (4-step turbo LoRA, t2v/i2v only — required for the 4-step option in the UI) | `minimax_h3_fl2v_turbo_4step_v1.2_768p_comfyui_bf16.safetensors` | `loras/H3/` | 1.9 GB | [resolve/main](https://huggingface.co/lightx2v/Minimax-h3-Turbo/resolve/main/minimax_h3_fl2v_turbo_4step_v1.2_768p_comfyui_bf16.safetensors) |

> **Caveat 1 — LTX 2.5 "gated"** (5 files marked ⚠️ gated above): the
> [`Lightricks/LTX-2.5`](https://huggingface.co/Lightricks/LTX-2.5) repository is
> access-restricted on Hugging Face — an anonymous download fails with a 401 until you've
> accepted the model's terms with an HF account **and** supplied an access token
> (`HF_TOKEN=<token> ./install-ubuntu.sh`, see the Deployment section above). This isn't a URL
> problem: the links are correct, access is simply gated by HF.
>
> **Caveat 2 — Minimax H3 "community reupload"** (3 files marked ⚠️ above): the 2 quantized
> `w4a8_mixed` checkpoints (`AX1Y2JP/MiniMax-H3-W4A8-ConvRot`) and the turbo LoRA
> (`koongrizzly/MiniMax_H3_int4_W4A8_ConvRot_Pruned`) do **not** come from an official
> Comfy-Org/Minimax repository, but from community reuploads. The filename and exact size
> match the expected specs and were verified via an actual HTTP request, but the integrity
> of the content is backed only by the repository's reputation/traction (tens of thousands
> of downloads), not by an official publisher. Worth noting before relying on it in
> production — without this being a red flag in itself.

> **Legacy models** (Flux2 Klein 9B, Ernie-Image, Z-Image, LTX 2.3): no longer used by the
> app (:8090), but still referenced by the drag-and-drop UI workflows `workflows/*.json`
> (`campaign_generator.json`, `storyboard_animatic.json`, `ernie_turbo.json`, `ernie_quality.json`,
> `localized_assets.json`) — see `workflows/README.md` if you still want to load them
> directly into ComfyUI.

### Required Ollama model

`gemma4:e4b` — pulled automatically when the `ollama` service starts (see above), or
manually:

```bash
curl -X POST http://localhost:11434/api/pull -d '{"model":"gemma4:e4b"}'
```

### Canvas mode (node editor)

In addition to the `index.html` form, the application offers a second mode: `canvas.html`, a
ComfyUI-style node editor (drag-and-drop cards, visual wiring). Accessible via
`http://<host>:8090/canvas.html`, or via the "Canvas" button in the header of the main
interface. This is an additional mode — it doesn't replace the `index.html` form, the two
coexist and share the same origin (no extra nginx/Docker configuration is needed). A drawer
docked at the bottom of the screen gives access to the generation history (Images/Videos
tabs), and a thumbnail can be dragged onto a "Media import" card to reuse it directly.

### `comfy_kitchen` acceleration

Every `workflows/api/*.json` template wires a `ModelAttentionBackend` node
(`comfy kitchen attention`), provided by [`comfy_kitchen`](https://github.com/Comfy-Org/comfy-kitchen)
— an official Comfy-Org package, not a third-party custom node and not specific to the
`mmartial/comfyui-nvidia-docker` image. The upstream `dellaicontent` repo builds it via an
ARM64-only userscript tied to that image's layout (`docker/userscripts/`, removed in this
fork, along with the image itself). This fork instead installs `comfy_kitchen` from its
official prebuilt PyPI wheel (`pip3 install comfy_kitchen`) directly in
`docker/comfyui-official/Dockerfile` — no build step. The wheel statically links its own CUDA
kernels and has no ABI dependency on the installed torch version, so there's no
version-matching risk. No compiler is needed either, so the image uses a `-runtime` base
rather than `-devel` — no extra manual step, it's part of the image build.

## Update

Deployments made from this commit onward (or from a later one) include an automatic update
check: when Studio (`index.html`) or Canvas (`canvas.html`) loads in the browser, the app
checks whether a newer version is available on GitHub. If one is, a popup offers to install
it; if you agree, the update downloads and applies automatically (`git pull` in the
background), then a second popup prompts you to refresh the browser.

**Older deployments** (installed before this feature was introduced, so without the
`updater` service): a one-time manual update is required to get the feature itself —
subsequent updates can then be done from the UI:

```bash
cd ai-content-studio
git pull origin main
docker compose up -d --build
```

`--build` is required here: it's what builds and starts the new `updater` service, which
didn't exist yet on this deployment.

## The 3 scenarios (see spec `ai_content_studio_media_entertainment_gb10.md`)

| Scenario | Dedicated pipelines | Deliverables |
|---|---|---|
| **Campaign Generator** | `campaign_full` (one job) + generic pipelines | 2:3 posters, 16:9 thumbnails, 1:1 social, vertical video teaser with audio |
| **Storyboard + Animatic** | `storyboard_v2` (charsheet+locsheet+keyframes+cuts), `reference2video` (Minimax H3, a single job), `sequence2video` (manual FLF2V) | N-shot storyboard + assembled animatic, OR a single video with a consistent character+setting, OR a manual first-frame→last-frame animatic, with audio |
| **Localized Assets** | image2image + target markets | Per-market variants (North America, Europe, Middle East, Asia…) via Qwen-Edit |

A **role-based navigation** layer (Director/Storyboard artist, Art director/Motion designer,
Social media/Marketing, Editor/Post-production) preselects scenario + pipeline without
changing the routing above.

Generic pipelines available everywhere: text2image (Krea 2 Turbo), image2image (Qwen-Edit
2509), text2video and image2video (LTX 2.5 and Minimax H3, selectable in the Model menu;
optional native audio, Minimax H3 turbo can be toggled on).

## Directory layout

```
index.html                  ← form mode (CSS + HTML + JS)
canvas.html                 ← node-editor mode (ComfyUI-style)
js/                         ← canvas mode engine (engine.js, nodes-simple.js, nodes-advanced.js)
install-ubuntu.sh            ← one-command idempotent install/update, Ubuntu 24.04 (recommended)
install-omarchy.sh           ← same, for Omarchy (Arch-based)
install-windows.ps1          ← one-command idempotent install/update, Windows 10/11 native (no Docker, dedicated NVIDIA GPU)
scripts/lib-install-common.sh ← application logic shared by both Linux install scripts
scripts/serve-windows.ps1    ← native PowerShell web server + reverse proxy, Windows equivalent of nginx.conf
docker-compose.yml          ← app only: nginx (8090) + updater (8093)
docker/stacks/*.yml         ← templates for the sibling stacks: ~/comfyui and ~/ollama
docker/comfyui-official/    ← Dockerfile building official ComfyUI (comfyanonymous/ComfyUI)
scripts/models.txt          ← 19 required models: folder|file|size|URL (source of truth for the install scripts and the README)
workflows/
  manifest.json             ← feeds the app's Pipeline/Model menus
  api/*.json                ← single-branch API templates with {{PROMPT}}… placeholders
  *.json                    ← full UI-format workflows (drag-and-drop into ComfyUI)
  README.md                 ← workflow details
tools/convert.py            ← UI→API converter (see docs/TESTING.md)
docs/
  INSTALL-X86.md            ← detailed install guide: Ubuntu 24.04 / Omarchy / Windows prerequisites & commands
  TROUBLESHOOTING.md        ← install/deploy troubleshooting: symptoms, diagnosis, repair, clean reinstall
  TROUBLESHOOTING.fr.md     ← same guide in French
  ARCHITECTURE.md           ← anatomy of the app and its formats
  LESSONS.md                ← pitfalls & validated patterns (READ BEFORE MODIFYING)
  TESTING.md                ← validation method (real renders, frame/audio extraction)
ai_content_studio_media_entertainment_gb10.md   ← original functional spec
dell_ai_content_studio_prototype.html           ← old prototype (legacy, unused)
```

## Picking the project back up

1. Read `CLAUDE.md` (conventions and commands), then `docs/LESSONS.md` **before making any changes to ComfyUI graphs** — the pitfalls documented there are costly to rediscover the hard way.
2. Any change to generation must be validated with an **actual render** AND a **visual/audio inspection** of the result (method in `docs/TESTING.md`) — a "success" job status can still produce wrong content.
3. The UI is checked with headless Chromium (multi-resolution screenshots, light/dark themes) — see `docs/TESTING.md`.
