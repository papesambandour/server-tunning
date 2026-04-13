# SERVER-TUNNING — Deploiement AI-YAS-KYC sur serveurs bare-metal

Setup et deploiement de l'API de verification d'identite KYC sur 2 serveurs Ubuntu avec load balancing Nginx.

## Architecture

```
                     Clients
                       │
                       ▼
               Nginx LB (:80)
               least_conn
              ┌────────────────┐
              ▼                ▼
      10.0.92.66:8000   10.0.92.67:8000
      8 workers gunicorn  8 workers gunicorn
      Python 3.9 natif    Python 3.9 natif
      RapidOCR + Tesseract OCRB
```

- **Pas de Docker** — Python natif pour maximiser la performance CPU
- **16 workers paralleles** — 8 par serveur (CPU/3 pour OCR CPU-bound)
- **Zero downtime** — deploiement rolling : un serveur a la fois, nginx bascule automatiquement
- **Un seul script** — `setup.sh` fait tout (install, config, deploy, operations)

## Fichiers

```
SERVER-TUNNING/
├── setup.sh          # Script unique : menu interactif
├── .env.example      # Template de configuration (a committer)
├── .env              # Config locale (NE PAS committer)
└── README.md
```

## Installation rapide

### 1. Preparer la config

```bash
cp .env.example .env
nano .env
```

Variables a adapter :

```env
KYC_GIT_REPO=https://github.com/votre-org/ai-yas-kyc.git
KYC_SERVER1=10.0.92.66
KYC_SERVER2=10.0.92.67
```

### 2. Premiere installation (sur chaque serveur)

```bash
# Copier setup.sh et .env sur le serveur (via scp ou Segura)
sudo bash setup.sh --env .env
```

Le menu s'affiche :

```
  ╔══════════════════════════════════════════════════╗
  ║         AI-YAS-KYC — Setup & Deploy             ║
  ╠══════════════════════════════════════════════════╣
  ║  Serveur : 10.0.92.66                           ║
  ║  App 1   : 10.0.92.66:8000                      ║
  ║  App 2   : 10.0.92.67:8000                      ║
  ╚══════════════════════════════════════════════════╝

  Etat du serveur :
    ✗  OS Tuning
    ✗  Python 3.9 + venv
    ✗  Tesseract + OCRB
    ✗  Code app
    ✗  Service systemd

  ── Installation ──
    1  OS Tuning
    2  Python + App + Service
    3  Nginx Load Balancer

  ── Deploiement ──
    4  Deploy

  ── Operations ──
    5  Start    6  Stop    7  Restart
    8  Logs     9  Test backends
    0  Quitter
```

Executer dans l'ordre :

| Etape | Serveur 1 (66) | Serveur 2 (67) |
|-------|---------------|---------------|
| OS Tuning | `1` | `1` |
| Python + App | `2` | `2` |
| Nginx LB | `3` | — |

### 3. Deploiement (a chaque mise a jour)

**Serveur 2 d'abord** (nginx bascule tout sur le serveur 1) :

```bash
# Via Segura
segura connect user@10.0.92.67
sudo bash /opt/kyc/setup.sh --env /opt/kyc/.env
# Menu → 4 (Deploy)
```

**Puis serveur 1** (nginx bascule tout sur le serveur 2 pendant le deploy) :

```bash
segura connect user@10.0.92.66
sudo bash /opt/kyc/setup.sh --env /opt/kyc/.env
# Menu → 4 (Deploy)
```

Le deploy fait :
1. **Stop** le service (nginx bascule le trafic)
2. **Git pull** (branch, tag, ou main)
3. **Deps** mises a jour si `requirements.txt` a change
4. **Modeles** verifies (ResNet18, RapidOCR)
5. **Start** le service
6. **Smoke test** (attend `/health`)
7. Affiche le **rollback** si echec

## Configuration .env

| Variable | Defaut | Description |
|----------|--------|-------------|
| `KYC_GIT_REPO` | — | URL du repo git (obligatoire) |
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
| `KYC_SERVER1` | `10.0.92.66` | IP serveur 1 (nginx + app) |
| `KYC_SERVER2` | `10.0.92.67` | IP serveur 2 (app uniquement) |
| `KYC_NGINX_SERVER` | `10.0.92.66` | IP du serveur nginx |
| `KYC_SWAP_SIZE` | `4G` | Taille swap de securite |

## Operations courantes

```bash
# Lancer le menu
sudo bash setup.sh --env .env

# Commandes directes (sans menu)
sudo systemctl start kyc
sudo systemctl stop kyc
sudo systemctl restart kyc
sudo systemctl status kyc
sudo journalctl -u kyc -f          # Logs live

# Test
curl http://127.0.0.1:8000/health  # Backend local
curl http://10.0.92.66/health       # Via nginx LB
```

## Tuning applique

### OS (option 1)

| Parametre | Valeur | Pourquoi |
|-----------|--------|----------|
| `vm.swappiness` | 10 | Swap en dernier recours |
| `vm.overcommit_memory` | 0 | Pas d'overcommit (PyTorch) |
| `fs.file-max` | 2M | Beaucoup de fichiers ouverts |
| `net.core.somaxconn` | 65535 | File d'attente connexions |
| CPU governor | performance | Frequence max sur les 24 cores |
| Swap | 4 GB | Securite OOM |

### Gunicorn (option 2)

| Parametre | Valeur | Pourquoi |
|-----------|--------|----------|
| Workers | CPU/3 = 8 | OCR CPU-bound, 3 threads/worker |
| Timeout | 120s | Images complexes |
| Max requests | 1000 | Recyclage anti-fuite memoire |
| `OMP_NUM_THREADS` | 2 | Limite threads ONNX par worker |
| `PYTORCH_NUM_THREADS` | 1 | Un document par worker |

### Nginx (option 3)

| Parametre | Valeur | Pourquoi |
|-----------|--------|----------|
| `least_conn` | — | Envoie vers le serveur le moins charge |
| `proxy_read_timeout` | 120s | OCR peut prendre du temps |
| `proxy_next_upstream` | 502/503/504 | Retry auto sur l'autre serveur |
| `max_fails` | 3 en 30s | Retire un backend defaillant |
| `keepalive` | 32 | Connexions persistantes vers backends |
| `client_max_body_size` | 20 MB | Upload images |

## Performance

| Metrique | Docker (ancien) | Bare-metal (actuel) |
|----------|----------------|---------------------|
| Workers total | 4 | **16** (8 × 2 serveurs) |
| Overhead | 10-15% | **0%** |
| Latence OCR | 2-3s | **1-2s** |
| Requetes paralleles | 4 | **16** |
| RAM utilisee | ~3 GB | ~6.4 GB / 32 GB |
| Deploy downtime | 30-60s | **0s** (rolling) |

## Rollback

Si un deploy echoue :

```bash
cd /opt/kyc
git log --oneline -5              # Voir les commits
git checkout <ancien-commit>      # Revenir
sudo systemctl restart kyc        # Redemarrer
```

## Securite

- Service tourne sous l'utilisateur `kyc` (pas root)
- `ProtectSystem=full` dans systemd
- `NoNewPrivileges=true`
- Nginx : `server_tokens off`
- Pas de donnees stockees (traitement en memoire)
