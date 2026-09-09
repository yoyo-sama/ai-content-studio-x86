# Guide d'installation — x86_64 / GPU NVIDIA dédié

Ce fork cible un poste **x86_64** équipé d'un **GPU NVIDIA dédié** (carte discrète classique,
pas le SoC unifié GB10/DGX Spark du repo source `dellaicontent`). Trois chemins d'installation
sont proposés : **Ubuntu 24.04** et **Omarchy**, qui tournent en Docker et partagent la même
logique applicative (`scripts/lib-install-common.sh` — seule la vérification des prérequis
système diffère), et **Windows 10/11** (`install-windows.ps1`), un installateur 100 % natif,
sans Docker, avec sa propre logique.

## Prérequis communs (Ubuntu / Omarchy — variante Docker)

- Machine **x86_64** avec un **GPU NVIDIA dédié**.
- **Driver NVIDIA propriétaire** installé et chargé (`nvidia-smi` doit fonctionner).
- **Docker** + le plugin **Docker Compose v2** (`docker compose version`).
- **`nvidia-container-toolkit`** configuré pour Docker (`nvidia-ctk runtime configure --runtime=docker`).
- Une connexion internet pour cloner ComfyUI officiel, télécharger les images de base et les
  modèles (`scripts/models.txt`, plusieurs dizaines de Go au total).

Les deux scripts d'installation (`install-ubuntu.sh`, `install-omarchy.sh`) **vérifient** ces
prérequis et affichent les commandes exactes s'il en manque — ils ne les installent pas
automatiquement (décision volontaire : pas d'action root implicite sur le système).

La variante Windows n'a besoin d'aucun de ces prérequis (pas de Docker, pas de toolkit) — voir
la section Windows plus bas.

## Ubuntu 24.04

### 1. Driver NVIDIA

```bash
sudo ubuntu-drivers autoinstall
sudo reboot
nvidia-smi   # doit afficher le GPU
```

### 2. Docker

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"   # puis se reconnecter (ou `newgrp docker`)
docker compose version            # vérifie le plugin v2
```

(Référence : [docs.docker.com/engine/install/ubuntu](https://docs.docker.com/engine/install/ubuntu/))

### 3. nvidia-container-toolkit

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

(Référence : [docs.nvidia.com container-toolkit install-guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html))

### 4. Installation de l'app

```bash
git clone <url-du-repo> ai-content-studio
cd ai-content-studio
./install-ubuntu.sh
```

## Omarchy (Arch Linux / Hyprland)

Omarchy tourne sous Hyprland/Wayland, mais l'installation est intégralement headless (Docker) —
l'environnement graphique n'a aucun impact ici.

### 1. Driver NVIDIA

```bash
sudo pacman -S --needed nvidia nvidia-utils
# Sur un noyau non standard (ex. linux-zen, linux-lts) : nvidia-dkms à la place de nvidia
sudo reboot
nvidia-smi   # doit afficher le GPU
```

### 2. Docker

```bash
sudo pacman -S --needed docker docker-compose
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"   # puis se reconnecter (ou `newgrp docker`)
docker compose version            # vérifie le plugin v2
```

### 3. nvidia-container-toolkit

Disponible dans le dépôt officiel `extra` d'Arch (sinon via l'AUR avec `yay`) :

```bash
sudo pacman -S --needed nvidia-container-toolkit
# si absent du dépôt 'extra' sur votre miroir :
yay -S nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

### 4. Installation de l'app

```bash
git clone <url-du-repo> ai-content-studio
cd ai-content-studio
./install-omarchy.sh
```

## Windows 11 / 10 (x86_64 + GPU NVIDIA dédié)

Contrairement aux variantes Ubuntu/Omarchy, cette installation est **100 % native, sans
Docker** — pas de conteneur, pas de `nvidia-container-toolkit`, pas de WSL2.

### 1. Driver NVIDIA

Seul prérequis : le **driver NVIDIA propriétaire à jour** (`nvidia-smi` doit fonctionner dans
une invite PowerShell ou CMD). C'est tout — pas de Docker, pas de WSL2, pas de Python
pré-installé, pas de 7-Zip pré-installé (le script télécharge lui-même `7zr.exe`, l'extracteur
minimal), pas de Visual Studio Build Tools (`comfy_kitchen` s'installe via une roue PyPI
précompilée, aucune compilation requise). PowerShell 5.1 et `curl.exe` sont nativement présents
sur Windows 10 (1803+) et Windows 11.

Installez le driver GeForce/Studio depuis [nvidia.com](https://www.nvidia.com/download/index.aspx)
si besoin, puis redémarrez.

### 2. Installation de l'app

```powershell
git clone <url-du-repo> ai-content-studio
cd ai-content-studio
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
```

`-ExecutionPolicy Bypass` est nécessaire : sans lui, PowerShell refuse par défaut d'exécuter un
script tout juste cloné (politique d'exécution par défaut de Windows).

Pour LTX 2.5 (dépôt Hugging Face "gated"), voir la section `HF_TOKEN` du `README.md` — la
variable s'utilise de la même façon sous Windows :

```powershell
$env:HF_TOKEN = "<votre_jeton>"; powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
```

## Ce que fait install-windows.ps1

Script autonome (n'appelle pas `scripts/lib-install-common.sh`, propre à la variante Windows),
en 7 étapes :

1. **1/7** Vérifie la présence d'un GPU NVIDIA (`nvidia-smi`) — avertit sans bloquer si absent.
2. **2/7** Télécharge et extrait le build ComfyUI portable officiel (build Nvidia, ~2 Go, depuis
   la dernière release GitHub) s'il n'est pas déjà présent.
3. **3/7** Installe `comfy_kitchen` en best-effort (accélération optionnelle, ne bloque jamais).
4. **4/7** Télécharge les modèles listés dans `scripts/models.txt` (idempotent, skip si déjà
   présent à la bonne taille).
5. **5/7** Détecte Ollama intelligemment : déjà en service → rien à faire ; installé mais
   éteint → démarré automatiquement ; vraiment absent → guide vers l'installeur officiel, sans
   rien installer à la place de l'utilisateur.
6. **6/7** Démarre ComfyUI et le serveur web.
7. **7/7** Affiche un récapitulatif final avec health-checks.

Relançable à volonté, comme les scripts Ubuntu/Omarchy : rien n'est retéléchargé ni recréé si
c'est déjà présent et valide.

`scripts/serve-windows.ps1` remplace nginx par un serveur PowerShell natif
(`System.Net.HttpListener`) qui sert les fichiers statiques du dépôt ET relaie `/comfy/*` vers
ComfyUI et `/ollama/*` vers Ollama — un reverse-proxy indispensable puisque le frontend appelle
ces API en chemins relatifs. Il est démarré automatiquement par `install-windows.ps1` ; pas
besoin de le lancer à la main.

### Limites connues (Windows)

1. **Pas de mise à jour automatique depuis l'UI** — le service `updater` Docker n'est pas porté
   sur cette variante. Mise à jour manuelle : `git pull` dans le dossier du dépôt.
2. **Le serveur web (`:8090`) n'écoute que sur `localhost` par défaut** — accessible depuis
   cette machine uniquement, pas depuis le réseau local (contrairement à la variante
   Linux/Docker, qui écoute sur toutes les interfaces). `scripts/serve-windows.ps1` contient en
   commentaire la commande exacte pour ouvrir l'accès LAN (`netsh http add urlacl` + une règle
   de pare-feu, à exécuter en administrateur) si besoin.
3. **La barre de progression des jobs ComfyUI n'est pas animée en temps réel** (le WebSocket
   n'est pas proxifié — purement cosmétique, la génération et la détection de fin fonctionnent
   normalement).

## Ce que font les scripts d'installation (Ubuntu / Omarchy)

`install-ubuntu.sh` et `install-omarchy.sh` sont deux enrobages fins, chacun spécifique à sa
distro pour la section 1/5 (vérification des prérequis système), qui appellent ensuite la même
logique commune (`scripts/lib-install-common.sh`) :

1. **1/5** Vérifications d'environnement (architecture x86_64, docker/docker compose,
   driver/toolkit NVIDIA).
2. **2/5** Détection des 3 services (web `:8090`, ComfyUI `:8188`, Ollama `:11434`) **par
   santé HTTP réelle**, pas par nom de conteneur — réutilise tout ce qui tourne déjà, **y
   compris un Ollama installé nativement (systemd), qui n'est pas un conteneur**, et ne
   recrée/ne détruit jamais un service qu'il ne possède pas (vérifié via les labels
   docker-compose). Les services manquants sont créés dans leur propre stack à la racine du
   home (`~/comfyui`, `~/ollama`) depuis les gabarits `docker/stacks/*.yml`, dossiers créés
   côté utilisateur AVANT les conteneurs (un bind-mount dont la source n'existe pas est créé
   par Docker en `root` : dossier cadenassé et téléchargements en échec ensuite). Si un port
   est occupé par un service qui ne répond pas — Ollama natif arrêté, par exemple — rien n'est
   créé et le script explique quoi faire, au lieu de laisser Docker échouer sur
   « port is already allocated ».
3. **3/5** Téléchargement des modèles manquants (`scripts/models.txt`) dans
   `~/comfyui/models/<dossier>/`, avec vérification de taille pour éviter les re-téléchargements
   inutiles. Refus explicite si le dossier n'est pas inscriptible.
4. **4/5** Pull du modèle Ollama `gemma4:e4b` s'il est absent, **par l'API HTTP**
   (`POST /api/pull`) et non par `docker exec` : identique que Ollama tourne dans notre
   conteneur, dans celui d'un autre projet, ou nativement.
5. **5/5** Récapitulatif final (statut des services, modèles, health-checks).

Ce script est idempotent : le relancer après une première installation réussie ne recrée rien
d'inutile, il ne fait que combler ce qui manque (modèles absents, services arrêtés).

## Build de l'image ComfyUI officielle

L'image ComfyUI n'est plus tirée (`docker pull`) d'un registre — elle est **buildée
localement** depuis `docker/comfyui-official/Dockerfile`, qui clone
[`comfyanonymous/ComfyUI`](https://github.com/comfyanonymous/ComfyUI) (dépôt officiel, pas de
fork ni de custom nodes — cf. `AGENTS.md`) et installe PyTorch avec les roues CUDA 12.4.
Le build est lancé par les scripts d'installation (`docker build -t ai-content-studio-comfyui:local
docker/comfyui-official`) ; la stack `~/comfyui/compose.yaml` ne référence que le tag, elle ne
contient aucun chemin vers le repo. Le premier build prend donc
plusieurs minutes (clone + `pip install`) ; les exécutions suivantes réutilisent le cache
Docker tant que le Dockerfile ne change pas.

## Dépannage

- **`nvidia-smi` introuvable après install du driver** : redémarrez la machine, le module
  noyau `nvidia` n'est chargé qu'après reboot dans le cas général.
- **ComfyUI démarre mais ne voit pas le GPU** : vérifiez `docker info | grep -i nvidia` et que
  `nvidia-ctk runtime configure --runtime=docker` a bien été exécuté puis Docker redémarré.
- **`pip install` échoue dans le build de l'image ComfyUI** : vérifiez la connectivité vers
  `download.pytorch.org` et `pypi.org` depuis la machine hôte (le build se fait sans accès au
  GPU, mais a besoin du réseau).
- **Fichiers modèles LTX 2.5 en échec (401)** : dépôt Hugging Face "gated", voir la section
  `HF_TOKEN` du `README.md`.
