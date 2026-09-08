# Guide d'installation — x86_64 / GPU NVIDIA dédié

Ce fork cible un poste **x86_64** équipé d'un **GPU NVIDIA dédié** (carte discrète classique,
pas le SoC unifié GB10/DGX Spark du repo source `dellaicontent`). Deux chemins d'installation
sont proposés, avec la même logique applicative (`scripts/lib-install-common.sh`) : seule la
vérification des prérequis système diffère.

## Prérequis communs

- Machine **x86_64** avec un **GPU NVIDIA dédié**.
- **Driver NVIDIA propriétaire** installé et chargé (`nvidia-smi` doit fonctionner).
- **Docker** + le plugin **Docker Compose v2** (`docker compose version`).
- **`nvidia-container-toolkit`** configuré pour Docker (`nvidia-ctk runtime configure --runtime=docker`).
- Une connexion internet pour cloner ComfyUI officiel, télécharger les images de base et les
  modèles (`scripts/models.txt`, plusieurs dizaines de Go au total).

Les deux scripts d'installation (`install-ubuntu.sh`, `install-omarchy.sh`) **vérifient** ces
prérequis et affichent les commandes exactes s'il en manque — ils ne les installent pas
automatiquement (décision volontaire : pas d'action root implicite sur le système).

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

## Ce que font les scripts d'installation

`install-ubuntu.sh` et `install-omarchy.sh` sont deux enrobages fins, chacun spécifique à sa
distro pour la section 1/5 (vérification des prérequis système), qui appellent ensuite la même
logique commune (`scripts/lib-install-common.sh`) :

1. **1/5** Vérifications d'environnement (architecture x86_64, docker/docker compose,
   driver/toolkit NVIDIA).
2. **2/5** Détection des 3 services (web `:8090`, ComfyUI `:8188`, Ollama `:11434`) **par
   santé HTTP réelle**, pas par nom de conteneur — réutilise tout ce qui tourne déjà et ne
   recrée/ne détruit jamais un conteneur qu'il ne possède pas (vérifié via les labels
   docker-compose).
3. **3/5** Téléchargement des modèles manquants (`scripts/models.txt`) dans
   `comfyui/models/<dossier>/`, avec vérification de taille pour éviter les re-téléchargements
   inutiles.
4. **4/5** Pull du modèle Ollama `gemma4:e4b` s'il est absent.
5. **5/5** Récapitulatif final (statut des services, modèles, health-checks).

Ce script est idempotent : le relancer après une première installation réussie ne recrée rien
d'inutile, il ne fait que combler ce qui manque (modèles absents, services arrêtés).

## Build de l'image ComfyUI officielle

L'image ComfyUI n'est plus tirée (`docker pull`) d'un registre — elle est **buildée
localement** depuis `docker/comfyui-official/Dockerfile`, qui clone
[`comfyanonymous/ComfyUI`](https://github.com/comfyanonymous/ComfyUI) (dépôt officiel, pas de
fork ni de custom nodes — cf. `AGENTS.md`) et installe PyTorch avec les roues CUDA 12.4.
Le premier `docker compose up -d comfyui` (ou `docker compose build comfyui`) prend donc
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
