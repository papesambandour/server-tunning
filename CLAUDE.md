# CLAUDE.md — server-tunning

## Projet

Script Bash interactif (`setup.sh`) pour installer, configurer et deployer des applications Python CPU-bound (OCR, IA, ML) sur des serveurs Ubuntu bare-metal avec load balancing Nginx.

Configurable via `.env` pour n'importe quelle app Python/Gunicorn.

## Fichiers

```
install.sh        # Bootstrap : telecharge setup.sh + .env dans ~/server-tunning/
setup.sh          # Script principal : menu interactif (install + deploy + ops)
.env.example      # Template de configuration (a committer)
.env              # Config locale (gitignored, jamais commite)
README.md         # Documentation utilisateur
CLAUDE.md         # Ce fichier
```

## Installation

```bash
# One-liner (telecharge dans ~/server-tunning/)
curl -fsSL https://raw.githubusercontent.com/papesambandour/server-tunning/master/install.sh | sudo bash

# Puis configurer et lancer
nano ~/server-tunning/.env
sudo bash ~/server-tunning/setup.sh --env ~/server-tunning/.env
```

## Architecture cible

```
Client → Nginx LB (:80, least_conn) → Serveur 1 (:8000) + Serveur 2 (:8000)
```

- 2 serveurs backend avec Gunicorn + Uvicorn workers
- 1 serveur Nginx load balancer (colocataire du serveur 1)
- Deploiement rolling zero-downtime (un serveur a la fois)
- Python natif (pas Docker) pour maximiser la performance CPU
- Compatible Ubuntu 22.04 et 24.04 (deadsnakes PPA pour Python 3.9)

## Menu setup.sh

| Option | Action | Idempotent |
|--------|--------|------------|
| 1 | Prerequis (git, curl, build-essential, sudo, htop, jq, vim...) | Oui |
| 2 | OS Tuning (sysctl, swap, CPU governor, ulimits) | Oui |
| 3 | Python + venv + pip + Tesseract OCRB + modeles IA + service systemd | Oui |
| 4 | Nginx load balancer (uniquement serveur LB) | Oui |
| 5 | Deploy : stop → git pull → deps → modeles → start → smoke test | Oui |
| 6-8 | Start / Stop / Restart service | — |
| 9 | Logs live (journalctl) | — |
| t | Test tous les backends + nginx | — |

Chaque option verifie si l'etape est deja faite (✓/✗) et propose de re-executer.

## Configuration .env

Toutes les valeurs sont dans le `.env` — rien n'est hardcode dans `setup.sh` :

```env
# Git
KYC_GIT_REPO=https://github.com/your-org/your-app.git
KYC_GIT_BRANCH=main

# Application
KYC_APP_USER=myapp                   # Utilisateur systeme
KYC_APP_DIR=/opt/myapp               # Dossier app
KYC_SERVICE=myapp                    # Nom service systemd
KYC_PYTHON_VERSION=python3.9         # Version Python

# Serveur
KYC_BIND_HOST=0.0.0.0
KYC_BIND_PORT=8000

# Gunicorn
KYC_WORKERS=auto                     # auto = CPU/3
KYC_TIMEOUT=120
KYC_MAX_REQUESTS=1000

# Infrastructure
KYC_SERVER1=192.168.1.10             # Serveur 1 (nginx + app)
KYC_SERVER2=192.168.1.11             # Serveur 2 (app)
KYC_NGINX_SERVER=192.168.1.10        # Serveur nginx

# OS
KYC_SWAP_SIZE=4G
```

Le `.env` est charge via `--env` argument ou auto-detecte a cote du script ou dans `/etc/kyc.env`.

## Conventions de code

- **Bash strict** : `set -euo pipefail`
- **Idempotent** : chaque fonction verifie l'etat avant d'agir
- **Couleurs** : `log()` bleu, `ok()` vert, `warn()` jaune, `fail()` rouge
- **Variables** : prefixe `KYC_` dans le `.env`, sans prefixe dans le script
- **Pas de SSH** : chaque serveur a son propre `setup.sh` + `.env`
- **Pas de Docker** : Python natif, service systemd, gunicorn
- **Ubuntu only** : apt-get, deadsnakes PPA, systemd

## Tuning specifique OCR/IA CPU-bound

```
Workers = CPU / 3    (PAS CPU * 2)
  → Chaque worker OCR utilise ~3 threads internes (ONNX + OpenCV + Tesseract)
  → CPU/3 workers × 3 threads = 100% CPU sans contention
  → Chaque worker charge ~800 MB de modeles

Variables d'environnement dans le service systemd :
  OMP_NUM_THREADS=2       # Limite threads ONNX par worker
  MKL_NUM_THREADS=2       # Limite threads MKL
  PYTORCH_NUM_THREADS=1   # Un document par worker
  OMP_THREAD_LIMIT=2      # Limite Tesseract
```

## Deploy rolling (option 5)

Le deploy est **local uniquement** (pas de SSH entre serveurs) :

```
1. Se connecter sur serveur 2 → menu 5 (Deploy)
   → Stop service → nginx bascule sur serveur 1
   → Git pull → deps → start → smoke test

2. Se connecter sur serveur 1 → menu 5 (Deploy)
   → Stop service → nginx bascule sur serveur 2
   → Git pull → deps → start → smoke test

3. Les deux serveurs sont a jour, zero downtime
```

## install.sh (bootstrap)

Le script `install.sh` est un bootstrap leger qui :
1. Cree `~/server-tunning/` dans le home du user qui l'execute
2. Telecharge `setup.sh` et `.env.example` depuis GitHub
3. Copie `.env.example` → `.env` s'il n'existe pas
4. Affiche les prochaines etapes

Appele via : `curl ... | sudo bash` — les fichiers arrivent dans `/root/server-tunning/`.

## Contribuer

- Ne jamais hardcoder d'IP, port, ou chemin — utiliser les variables du `.env`
- Tester sur Ubuntu 24.04 (Docker : `docker run --rm -it ubuntu:24.04 bash`)
- Le script doit etre idempotent (relancer n'importe quelle option sans casser)
- Ne pas ajouter de dependance SSH entre les serveurs
- Ajouter `sudo` dans les prerequis (absent sur Ubuntu minimal/Docker)

## Langue

Documentation et messages console en **francais**.
