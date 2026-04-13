# server-tunning

Script Bash interactif pour installer, configurer et deployer des applications Python CPU-bound (OCR, IA, ML) sur des serveurs Ubuntu bare-metal avec load balancing Nginx.

Optimise pour les workloads **CPU-bound** : OCR (PaddleOCR, Tesseract, docTR), inference PyTorch/ONNX, traitement d'images.

## Architecture

```
                     Clients
                       │
                       ▼
               Nginx LB (:80)
               least_conn
              ┌────────────────┐
              ▼                ▼
     Serveur 1 (:8000)  Serveur 2 (:8000)
     N workers gunicorn   N workers gunicorn
     Python natif          Python natif
```

- **Pas de Docker** — Python natif pour maximiser la performance CPU
- **Workers = CPU / 3** — optimise pour les workloads CPU-bound (OCR, IA)
- **Zero downtime** — deploiement rolling : un serveur a la fois, nginx bascule automatiquement
- **Un seul script** — `setup.sh` fait tout (install, config, deploy, operations)
- **100% configurable** — toutes les valeurs dans un `.env`

## Installation rapide (une seule commande)

```bash
curl -fsSL https://raw.githubusercontent.com/papesambandour/server-tunning/main/install.sh | sudo bash
```

Cette commande telecharge `setup.sh` et `.env.example` dans `~/server-tunning/`, puis lance le menu.

Ou manuellement :

```bash
# 1. Telecharger dans ~/server-tunning/
mkdir -p ~/server-tunning && cd ~/server-tunning
curl -fsSL https://raw.githubusercontent.com/papesambandour/server-tunning/main/setup.sh -o setup.sh
curl -fsSL https://raw.githubusercontent.com/papesambandour/server-tunning/main/.env.example -o .env
chmod +x setup.sh

# 2. Configurer
nano .env

# 3. Lancer
sudo bash setup.sh --env .env
```

Ou via git clone :

```bash
git clone https://github.com/papesambandour/server-tunning.git ~/server-tunning
cd ~/server-tunning
cp .env.example .env
nano .env
sudo bash setup.sh --env .env
```

Le menu interactif s'affiche :

```
  ╔══════════════════════════════════════════════════╗
  ║         App — Setup & Deploy                    ║
  ╠══════════════════════════════════════════════════╣
  ║  Serveur : 192.168.1.10                         ║
  ║  App 1   : 192.168.1.10:8000                    ║
  ║  App 2   : 192.168.1.11:8000                    ║
  ╚══════════════════════════════════════════════════╝

  Etat du serveur :
    ✗  Prerequis (git, curl, build-essential)
    ✓  OS Tuning (sysctl, ulimits)
    ✓  Python 3.9 + venv
    ✗  Code app
    ✗  Service systemd

  ── Installation ──
    1  Prerequis (git, curl, build-essential, htop, jq...)
    2  OS Tuning (kernel, swap, CPU governor)
    3  Python + App + Service systemd
    4  Nginx Load Balancer (serveur LB uniquement)

  ── Deploiement ──
    5  Deploy (git pull + restart)

  ── Operations ──
    6  Start    7  Stop    8  Restart
    9  Logs     t  Test backends
    0  Quitter
```

## Installation

### Sur chaque serveur applicatif

```bash
sudo bash setup.sh --env .env
# → 1 (Prerequis)
# → 2 (OS Tuning)
# → 3 (Python + App + Service)
```

### Sur le serveur Nginx (un seul)

```bash
sudo bash setup.sh --env .env
# → 4 (Nginx Load Balancer)
```

## Deploiement

Deploiement rolling zero-downtime — un serveur a la fois :

```bash
# 1. Se connecter sur le serveur 2
ssh user@serveur-2
sudo bash setup.sh --env .env
# → 5 (Deploy) — nginx bascule le trafic sur le serveur 1

# 2. Se connecter sur le serveur 1
ssh user@serveur-1
sudo bash setup.sh --env .env
# → 5 (Deploy) — nginx bascule le trafic sur le serveur 2

# Resultat : zero downtime, les 2 serveurs sont a jour
```

Le deploy fait automatiquement :
1. **Stop** le service (nginx bascule le trafic)
2. **Git pull** (branch, tag, ou main)
3. **Deps** mises a jour si `requirements.txt` a change
4. **Start** le service
5. **Smoke test** (attend `/health`)

## Configuration .env

```bash
cp .env.example .env
```

| Variable | Defaut | Description |
|----------|--------|-------------|
| `KYC_GIT_REPO` | — | URL du repo git de l'app |
| `KYC_GIT_BRANCH` | `main` | Branche par defaut |
| `KYC_APP_USER` | `kyc` | Utilisateur systeme |
| `KYC_APP_DIR` | `/opt/kyc` | Dossier de l'application |
| `KYC_SERVICE` | `kyc` | Nom du service systemd |
| `KYC_PYTHON_VERSION` | `python3.9` | Version Python |
| `KYC_BIND_HOST` | `0.0.0.0` | Adresse d'ecoute |
| `KYC_BIND_PORT` | `8000` | Port de l'API |
| `KYC_WORKERS` | `auto` | Workers gunicorn (`auto` = CPU/3) |
| `KYC_TIMEOUT` | `120` | Timeout gunicorn (secondes) |
| `KYC_MAX_REQUESTS` | `1000` | Recyclage workers (evite fuites memoire) |
| `KYC_SERVER1` | `192.168.1.10` | IP serveur 1 (nginx + app) |
| `KYC_SERVER2` | `192.168.1.11` | IP serveur 2 (app) |
| `KYC_NGINX_SERVER` | `192.168.1.10` | IP du serveur nginx |
| `KYC_SWAP_SIZE` | `4G` | Taille swap de securite |

## Tuning applique

### OS (option 1)

| Parametre | Valeur | Pourquoi |
|-----------|--------|----------|
| `vm.swappiness` | 10 | Swap en dernier recours uniquement |
| `vm.overcommit_memory` | 0 | Refuse les allocations excessives (PyTorch) |
| `fs.file-max` | 2M | Support de nombreux fichiers ouverts |
| `net.core.somaxconn` | 65535 | File d'attente connexions elevee |
| CPU governor | performance | Frequence CPU max permanente |
| Swap | configurable | Securite OOM (evite les kills) |
| ulimit nofile | 1M | Pas de limite fichiers ouverts |

### Gunicorn (option 2)

| Parametre | Valeur | Pourquoi |
|-----------|--------|----------|
| Workers | CPU/3 | OCR CPU-bound : 3 threads internes par worker |
| Timeout | 120s | Traitements longs (images complexes) |
| Max requests | 1000 | Recyclage anti-fuite memoire |
| `OMP_NUM_THREADS` | 2 | Limite threads ONNX par worker |
| `PYTORCH_NUM_THREADS` | 1 | Un document par worker, pas de parallelisme |
| `ORT_NUM_THREADS` | 2 | Limite ONNX Runtime |

### Pourquoi CPU/3 et pas CPU×2 ?

```
FAUX :  CPU×2 workers (ex: 48 pour 24 cores)
  → 48 workers × 800 MB modeles = 38 GB > RAM disponible → OOM kill
  → 48 workers × 3 threads = 144 threads → contention CPU severe

VRAI :  CPU/3 workers (ex: 8 pour 24 cores)
  → 8 workers × 800 MB = 6 GB RAM
  → 8 workers × 3 threads = 24 threads = 100% CPU sans contention
```

### Nginx (option 3)

| Parametre | Valeur | Pourquoi |
|-----------|--------|----------|
| `least_conn` | — | Envoie vers le serveur le moins charge |
| `proxy_read_timeout` | 120s | Traitements longs |
| `proxy_next_upstream` | 502/503/504 | Retry auto sur l'autre backend |
| `max_fails` | 3 en 30s | Retire un backend defaillant |
| `keepalive` | 32 | Connexions persistantes vers backends |
| `client_max_body_size` | 20 MB | Upload fichiers |
| `gzip` | on | Compression reponses JSON |

## Operations

```bash
# Menu interactif
sudo bash setup.sh --env .env

# Commandes directes
sudo systemctl start myapp
sudo systemctl stop myapp
sudo systemctl restart myapp
sudo systemctl status myapp
sudo journalctl -u myapp -f          # Logs live

# Test
curl http://127.0.0.1:8000/health    # Backend local
curl http://serveur-nginx/health      # Via LB
```

## Rollback

```bash
cd /opt/myapp
git log --oneline -5              # Voir les commits
git checkout <ancien-commit>      # Revenir en arriere
sudo systemctl restart myapp      # Redemarrer
```

## Securite

- Service tourne sous un utilisateur dedie (pas root)
- `ProtectSystem=full` dans systemd
- `NoNewPrivileges=true`
- Nginx : `server_tokens off`
- `.env` dans `.gitignore` (jamais commite)

## Prerequis

- Ubuntu 22.04 ou 24.04
- Acces root (sudo)
- Git installe sur le serveur
- Connexion internet (pour git clone + pip install)

## License

MIT
