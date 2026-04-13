# CLAUDE.md — server-tunning

## Projet

Script Bash interactif (`setup.sh`) pour installer, configurer et deployer des applications Python CPU-bound (OCR, IA) sur des serveurs Ubuntu bare-metal avec load balancing Nginx.

Configurable via `.env` pour n'importe quelle app Python/Gunicorn.

## Architecture cible

```
Client → Nginx LB (:80, least_conn) → Serveur 1 (:8000) + Serveur 2 (:8000)
```

- 2 serveurs backend avec Gunicorn + Uvicorn workers
- 1 serveur Nginx load balancer (colocataire du serveur 1)
- Deploiement rolling zero-downtime (un serveur a la fois)
- Python natif (pas Docker) pour maximiser la performance CPU

## Fichiers

```
setup.sh          # Script unique : menu interactif (install + deploy + ops)
.env.example      # Template de configuration
.env              # Config locale (gitignored)
README.md         # Documentation complete
CLAUDE.md         # Ce fichier
```

## Le script setup.sh

Un seul script fait tout via un menu interactif :

| Option | Action | Idempotent |
|--------|--------|------------|
| 1 | OS Tuning (sysctl, swap, CPU governor, ulimits) | Oui — verifie avant |
| 2 | Python + venv + pip + Tesseract OCRB + modeles IA + service systemd | Oui |
| 3 | Nginx load balancer (uniquement serveur 1) | Oui |
| 4 | Deploy : stop → git pull → deps → modeles → start → smoke test | Oui |
| 5-7 | Start / Stop / Restart service | — |
| 8 | Logs live (journalctl) | — |
| 9 | Test tous les backends + nginx | — |

Chaque option verifie si l'etape est deja faite (✓/✗) et propose de re-executer ou non.

## Configuration

Toutes les valeurs sont dans le `.env` — rien n'est hardcode dans `setup.sh` :

```env
KYC_GIT_REPO=https://github.com/your-org/your-app.git  # Repo git de l'app
KYC_GIT_BRANCH=main                             # Branche par defaut
KYC_APP_USER=kyc                                # Utilisateur systeme
KYC_APP_DIR=/opt/kyc                            # Dossier app
KYC_SERVICE=kyc                                 # Nom service systemd
KYC_PYTHON_VERSION=python3.9                    # Version Python
KYC_BIND_HOST=0.0.0.0                           # Adresse ecoute
KYC_BIND_PORT=8000                              # Port API
KYC_WORKERS=auto                                # auto = CPU/3
KYC_TIMEOUT=120                                 # Timeout gunicorn
KYC_MAX_REQUESTS=1000                           # Recyclage workers
KYC_SERVER1=192.168.1.10                        # IP serveur 1
KYC_SERVER2=192.168.1.11                        # IP serveur 2
KYC_NGINX_SERVER=192.168.1.10                   # IP nginx
KYC_SWAP_SIZE=4G                                # Swap securite OOM
```

Le `.env` est charge via `--env` argument ou auto-detecte a cote du script.

## Conventions de code

- **Bash strict** : `set -euo pipefail`
- **Idempotent** : chaque fonction verifie l'etat avant d'agir
- **Couleurs** : `log()` bleu, `ok()` vert, `warn()` jaune, `fail()` rouge
- **Sections** : `section()` pour les separateurs visuels
- **Variables** : prefixe `KYC_` dans le `.env`, sans prefixe dans le script
- **Pas de SSH** : chaque serveur a son propre `setup.sh` + `.env` — pas de deploy distant

## Tuning specifique OCR/IA

Regles importantes pour les apps CPU-bound (PyTorch, ONNX, Tesseract) :

```
Workers = CPU / 3    (PAS CPU * 2)
  → Chaque worker OCR utilise ~3 threads internes
  → CPU/3 workers × 3 threads = 100% CPU sans contention
  → Chaque worker charge ~800 MB de modeles

Variables d'environnement dans le service systemd :
  OMP_NUM_THREADS=2       # Limite threads ONNX par worker
  MKL_NUM_THREADS=2       # Limite threads MKL
  PYTORCH_NUM_THREADS=1   # Un document par worker
  OMP_THREAD_LIMIT=2      # Limite Tesseract
```

## Deploy rolling

Le deploy est **local uniquement** (pas de SSH entre serveurs) :

```
1. Se connecter sur serveur 2 → menu 4 (Deploy)
   → Stop service → nginx bascule sur serveur 1
   → Git pull → deps → start → smoke test

2. Se connecter sur serveur 1 → menu 4 (Deploy)
   → Stop service → nginx bascule sur serveur 2
   → Git pull → deps → start → smoke test

3. Les deux serveurs sont a jour, zero downtime
```

## Commandes

```bash
# Installation
sudo bash setup.sh --env .env

# Deploiement
sudo bash setup.sh --env .env    # → option 4

# Operations directes (sans menu)
sudo systemctl start|stop|restart|status kyc
sudo journalctl -u kyc -f
curl http://127.0.0.1:8000/health
```

## Contribuer

- Ne jamais hardcoder d'IP, port, ou chemin — utiliser les variables du `.env`
- Tester sur Ubuntu 22.04 et 24.04
- Le script doit etre idempotent (relancer n'importe quelle option sans casser)
- Ne pas ajouter de dependance SSH entre les serveurs

## Langue

Documentation et messages console en **francais**.
