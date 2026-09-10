# Troubleshooting — install and deployment (Ubuntu / Omarchy, x86_64)

*Version française : [TROUBLESHOOTING.fr.md](TROUBLESHOOTING.fr.md).*

This guide covers installing and running the stack, not render quality (see `docs/TESTING.md`)
nor pipeline pitfalls (see `docs/LESSONS.md`). For the native Windows install, see
`docs/INSTALL-X86.md`.

Replace `./install-ubuntu.sh` with `./install-omarchy.sh` depending on your distribution: the
logic is shared (`scripts/lib-install-common.sh`), only the system package checks differ.

## Common symptoms and their real cause

| What you see | Cause | Section |
|---|---|---|
| `Error: JSON.parse: unexpected character at line 1 column 1` | The response body is not JSON but nginx's **HTML** error page (502/504): ComfyUI or Ollama is not answering behind the reverse proxy | [1](#1-diagnosis-in-three-commands) |
| `Enhancement failed: NetworkError when attempting to fetch resource` | The request to `/ollama/api/chat` never completed (connection refused or dropped) | [1](#1-diagnosis-in-three-commands) |
| ComfyUI runs but sees no model | The models were downloaded into a folder this particular ComfyUI does not read | [2](#2-comfyui-does-not-see-the-models) |
| A padlock on `comfyui/` in the file manager | Folder created by dockerd as `root:root` (bind-mount whose source did not exist) — every model download then fails with "permission denied" | [2](#2-comfyui-does-not-see-the-models) |
| `skipped (native Ollama installed but not started)` | Ollama is installed outside Docker (the common case on Ubuntu) and its service is stopped | [3](#3-ollama-container-or-native-install) |
| `skipped (port 11434 busy)` / `port is already allocated` | Another process holds the port | [3](#3-ollama-container-or-native-install) |
| The ComfyUI image build fails | Network, or PyTorch/CUDA dependencies — the image is **built locally**, it is not pulled from a registry | [4](#4-the-comfyui-image) |
| You are reinstalling on a machine where a previous version of the script already ran | Migration from the old layout to the sibling stacks | [5](#5-reinstalling-on-a-machine-where-a-previous-version-of-the-script-already-ran) |

**The prompt language is never the cause.** A `JSON.parse` failing at "line 1 column 1" means
the very first character received is not JSON (typically the `<` of `<html>`): the error
happens before any of the text you typed is even read.

## 1. Diagnosis in three commands

The application exposes a single port (8090) and reaches ComfyUI and Ollama through the nginx
reverse proxy. So test through that proxy, exactly like the browser does:

```bash
for u in /comfy/system_stats /ollama/api/version /update/status; do printf '%s -> ' "$u"; curl -s -o /dev/null -w '%{http_code}\n' "http://localhost:8090$u"; done
```

Three `200` means the services answer. A `502` or `504` on `/comfy/` or `/ollama/` is exactly
what produces the `JSON.parse` error in the browser. Then:

```bash
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' | grep -iE 'comfy|ollama|content-studio'
```

An `Exited` container explains everything: the install script restarts it (it never creates a
duplicate), just run it again. Finally, the logs of whichever service is silent:

```bash
docker logs --tail 50 comfyui-nvidia
```

## 2. ComfyUI does not see the models

The container's mounts are the source of truth, not the path you think you configured:

```bash
docker inspect comfyui-nvidia --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'
```

Expected: `<home>/comfyui/models -> /comfyui/models`. If you see a path under
`~/ai-content-studio/comfyui/`, the container dates from the old layout (see
[section 5](#5-reinstalling-on-a-machine-where-a-previous-version-of-the-script-already-ran)).
Then the truth on the ComfyUI side — what it actually offers in its menus:

```bash
curl -s http://localhost:8188/object_info/UNETLoader | grep -o 'minimax_h3[^"]*' | head -3
```

An empty answer while the files do exist means ComfyUI is not reading that folder.

### Checking the integrity of downloaded models

```bash
M=~/comfyui/models; while IFS='|' read -r d f s u; do case "$d" in ''|\#*) continue;; esac; case "$s" in ''|*[!0-9]*) continue;; esac; a=$(stat -c%s "$M/$d/$f" 2>/dev/null || echo 0); t=$((s/100)); [ "$t" -lt 1 ] && t=1; if [ "$a" -eq 0 ]; then r=MISSING; elif [ "$a" -ge $((s-t)) ] && [ "$a" -le $((s+t)) ]; then r=OK; else r=INCOMPLETE; fi; printf '%-11s %s\n' "$r" "$d/$f"; done < ~/ai-content-studio/scripts/models.txt
```

`MISSING` and `INCOMPLETE` are fixed by running the install script again (`curl -C -` resumes
an interrupted download).

**Known limit of this check**: the tolerance is 1%, the same as the script uses, and it is
necessary — republished Hugging Face revisions make some files differ by a few kilobytes from
the sizes in `scripts/models.txt` without being corrupt. A file truncated by less than 1% would
therefore pass as good. The only proof that counts remains an actual render, inspected
(`docs/TESTING.md`) — a ComfyUI job reporting "success" proves nothing.

## 3. Ollama: container or native install

The script detects Ollama **by its service** (`:11434`), not by a container. On Ubuntu, the
official install (`curl -fsSL https://ollama.com/install.sh | sh`) creates a systemd service:
it is reused as is, no container is created, and the `gemma4:e4b` model is pulled through the
HTTP API. Check and manual pull, valid in both cases:

```bash
curl -s http://localhost:11434/api/tags | grep -o '"gemma4:e4b"' || curl -X POST http://localhost:11434/api/pull -d '{"model":"gemma4:e4b"}'
```

If the summary shows `skipped (native Ollama installed but not started)`, a native Ollama
exists but does not answer and the script could not start it (no passwordless sudo). No
container is created in that case — deliberately, so that two Ollama instances never fight
over port 11434:

```bash
sudo systemctl enable --now ollama
```

Then run the install script again. If the port is held by something else,
`sudo ss -ltnp 'sport = :11434'` tells you by what.

## 4. The ComfyUI image

Unlike the GB10 source repository, the image is not pulled from a registry: it is **built
locally** from `docker/comfyui-official/Dockerfile` (clone of the official ComfyUI + PyTorch
cu124 + `comfy_kitchen` as a PyPI wheel) and tagged `ai-content-studio-comfyui:local`. The
`~/comfyui/compose.yaml` stack only references that tag.

```bash
docker images | grep ai-content-studio-comfyui
```

No image? The build failed and the `docker compose up` behind it had nothing to start. Replay
it on its own to see the error in plain text (several minutes):

```bash
docker build -t ai-content-studio-comfyui:local ~/ai-content-studio/docker/comfyui-official
```

## 5. Reinstalling on a machine where a previous version of the script already ran

This is the most frequent case: a first install was attempted before v1.0.4, when
`docker-compose.yml` also declared `comfyui` and `ollama` with their volumes under
`~/ai-content-studio/comfyui/`.

**What the script does on its own**: it recognises the containers created by the repository's
`docker-compose.yml` (compose label), removes them, recreates ComfyUI in `~/comfyui` and Ollama
in `~/ollama`, and **copies** the weights from the `ollama-data` volume into `~/ollama/data` so
the model is not downloaded again. If Ollama is installed natively on the machine, no Ollama
stack is created at all: the existing service is reused.

It also moves the ComfyUI models from the old folder into the new one, before any download
(see step 3). It deletes nothing besides the inherited containers: the old folder, once emptied
of its files, stays on disk.

### Step 1 — Get the current version of the script

```bash
cd ~/ai-content-studio && git pull && cat VERSION
```

The version must be **≥ 1.0.5**. Below that you would be running the very version that caused
the problem. If `git pull` refuses because of local changes, `git stash` them: there is
normally nothing worth keeping in this repository on a deployment machine.

### Step 2 — Take stock

```bash
du -sh ~/ai-content-studio/comfyui/models 2>/dev/null; du -sh ~/comfyui/models 2>/dev/null; docker run --rm -v ollama-data:/v alpine sh -c 'du -sh /v; ls /v/models/manifests/registry.ollama.ai/library' 2>/dev/null; curl -s http://localhost:11434/api/version; df -h /home | tail -1
```

Five pieces of information: what the old folder holds, what the new one already holds, whether
the inherited Ollama volume really contains `gemma4`, whether an Ollama (native or container)
already answers, and the free space. You need **~150 GB** for the full set of ComfyUI models.

### Step 3 — The old model folder: nothing to do (unless padlocked)

**The script handles it.** At step 3/5, before any download, it moves the content of
`~/ai-content-studio/comfyui/models` into the folder the running ComfyUI actually reads. The
move is done file by file (a sub-folder present on both sides does not block it) and never
overwrites a file already at the destination. Moved models whose size matches are then
recognised and **not downloaded again**:

```
1 file(s) found in the legacy model folder (/home/<you>/ai-content-studio/comfyui/models).
Moving them to /home/<you>/comfyui/models — same filesystem, instant, and avoids downloading them again.
  moved: 1   left behind: 0
SKIP (already present, size matches): /home/<you>/comfyui/models/vae/qwen_image_vae.safetensors
```

**The only case where you must step in**: `left behind` is not zero. The old folder was created
by Docker as root (the padlock), so you have no right to move anything out of it. The script
prints the exact command; take ownership then run it again and it will finish the move:

```bash
sudo chown -R "$(id -u):$(id -g)" ~/ai-content-studio/comfyui
```

Once `left behind: 0`, the old folder only holds empty directories:

```bash
rm -rf ~/ai-content-studio/comfyui
```

### Step 4 — Run the install

```bash
cd ~/ai-content-studio && HF_TOKEN=<your_hf_token> ./install-ubuntu.sh 2>&1 | tee ~/install-$(date +%F-%H%M).log
```

`HF_TOKEN` is not optional in practice: the 4 LTX 2.5 files come from a *gated* Hugging Face
repository and fail cleanly without a token (the other 16 download normally). The `tee` keeps a
trace: the command runs for hours.

Order of operations, with the durations to expect:

| Script step | What happens | Duration |
|---|---|---|
| 2/5 | Inherited containers removed, ComfyUI image built, both stacks created | several minutes (build) |
| 2/5 | Ollama weights copied from the `ollama-data` volume | a few minutes (9.6 GB) |
| 3/5 | Missing ComfyUI models downloaded | several hours |
| 4/5 | `gemma4:e4b` pulled if missing | a few minutes |
| 4/5 | Waiting for ComfyUI's first start | up to 10 min |

### Step 5 — What you should see scroll by

The lines that prove the migration actually happened:

```
WARNING: ComfyUI inherited from the old layout — migrating to /home/<you>/comfyui.
Creating the ComfyUI stack in /home/<you>/comfyui.
Building the ComfyUI image (ai-content-studio-comfyui:local) — first build takes several minutes.
WARNING: Ollama inherited from the old layout — migrating to /home/<you>/ollama.
Copying weights from the 'ollama-data' volume into /home/<you>/ollama/data…
Waiting for ComfyUI on :8188 (first start)…
```

If Ollama is installed natively, the Ollama migration line is replaced by
`Ollama already running outside Docker (native/systemd service) — reusing it.` That is the
expected behaviour: no Ollama container is created.

If you see `reused (comfyui-nvidia)` with no migration line, the container does not carry the
repository's compose label: it was created by hand (`docker run`) or by another stack. The
script never touches a container it does not own — delete it yourself after checking where it
came from with the inventory in [section 6](#inventory-first--who-owns-what), then run the
script again.

### Step 6 — Read the log back

```bash
grep -nE "WARNING|failed|skipped|ERROR" ~/install-*.log
```

On a healthy install, all that remains are possible warnings about the LTX 2.5 files if
`HF_TOKEN` was missing.

### Step 7 — Verify

Run the script again: it is idempotent, and that is the best test.

```bash
cd ~/ai-content-studio && ./install-ubuntu.sh 2>&1 | tail -25
```

Expected: `reused` on the services, `already present (not re-downloaded) : 20`,
`Ollama model gemma4:e4b: present`, four `HTTP 200`. Then the check that really matters — does
ComfyUI see its models:

```bash
docker inspect comfyui-nvidia --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' && curl -s http://localhost:8188/object_info/UNETLoader | grep -o 'minimax_h3[^"]*' | head -3
```

Finally, in the application (`http://<ip>:8090`): **✨ Enhance (LLM)** on a prompt field, then a
simple image generation (Krea 2) before trying video.

### If the script stops midway

Just run it again. It is idempotent at every step: downloads resume where they stopped
(`curl -C -`), stacks already created are reused, stopped containers are restarted instead of
being duplicated, and the ComfyUI image is only rebuilt when the Dockerfile changed. Three
special cases:

- **Interrupted while copying the Ollama weights**: `~/ollama/data` is incomplete, the model
  will simply be pulled through the API on the next run.
- **ComfyUI image build failed**: see [section 4](#4-the-comfyui-image), replaying it alone
  shows the error in plain text.
- **Disk full during downloads**: partial files are kept; free some space and run again, the
  resume avoids starting over.

## 6. Starting from scratch

### Inventory first — who owns what

```bash
for c in $(docker ps -a --format '{{.Names}}'); do printf '%-30s %-48s %s\n' "$c" "$(docker inspect -f '{{.Config.Image}}' "$c")" "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$c")"; done
```

The third column decides: containers pointing at `<home>/ai-content-studio/docker-compose.yml`
come from the install you are redoing. An empty column means a container created outside
compose (`docker run`). A different file means another stack — leave it alone.

### Targeted reset (recommended)

Destroys the install, **keeps the built ComfyUI image and the models already downloaded**. This
command only removes containers created by this repository's `docker-compose.yml` — exactly
those of a failed install, including the `comfyui`/`ollama` ones from the old layout — and
cannot touch a neighbouring stack:

```bash
docker ps -a --format '{{.Names}}' | while read -r c; do [ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$c" 2>/dev/null)" = "$HOME/ai-content-studio/docker-compose.yml" ] && docker rm -f "$c"; done; sudo rm -rf ~/ai-content-studio/comfyui ~/ai-content-studio/.env
```

If the inventory showed a ComfyUI or an Ollama **without a label** (created outside compose),
the command above will not remove it: delete it by name, after checking it really comes from
your install attempt. A **native** Ollama (systemd) is not removed that way:
`sudo systemctl disable --now ollama` if you want to switch back to the containerised one.

### Full reset

Everything goes, including the ComfyUI image (to rebuild, several minutes) and **the models
(~150 GB, several hours of downloading)**:

```bash
docker rm -f ai-content-studio-web ai-content-studio-updater comfyui-nvidia ollama-api 2>/dev/null; docker volume rm ollama-data 2>/dev/null; docker rmi ai-content-studio-comfyui:local ollama/ollama:latest ai-content-studio-updater 2>/dev/null; sudo rm -rf ~/comfyui ~/ollama ~/ai-content-studio
```

Read the inventory again first: `~/comfyui` may hold valid models. When in doubt, keep
`~/comfyui/models` — files already present are never downloaded again.

### Reinstall

```bash
git clone https://github.com/yoyo-sama/ai-content-studio-x86.git ~/ai-content-studio && cd ~/ai-content-studio && HF_TOKEN=<your_hf_token> ./install-ubuntu.sh
```

### What you must not delete

Docker, the NVIDIA driver and `nvidia-container-toolkit` are never the cause of a failed
install of this stack, and the scripts do not install them — they check they are there and
print what to run (`apt` or `pacman` packages depending on the distro) if one is missing.
`docker system prune -a` would reclaim space but force a re-pull of every image and a rebuild
of ComfyUI: keep it for a saturated disk.

## 7. Checking that an install holds

The best test is to run the script again: it is idempotent.

```bash
cd ~/ai-content-studio && ./install-ubuntu.sh 2>&1 | tail -25
```

Expected: `reused` on the services, `already present (not re-downloaded) : 20`,
`Ollama model gemma4:e4b: present`, and four `HTTP 200` health checks. Only then open
`http://<ip>:8090`, test **✨ Enhance (LLM)** on a prompt field, then a simple image generation
(Krea 2) before trying video.
