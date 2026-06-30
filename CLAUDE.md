# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Projet

`server-tunning` est un outil 100% Bash (pas de Go, pas de Python applicatif ici) pour installer, tuner, et deployer une application **Python CPU-bound** (OCR, IA, ML) sur des serveurs Ubuntu bare-metal, derriere un load balancer Nginx. Le code de l'app cible n'est PAS dans ce repo : `setup.sh` le clone depuis `KYC_GIT_REPO`.

Optimise pour OCR/inference (PaddleOCR/RapidOCR, Tesseract, ONNX Runtime, PyTorch) : Python natif (pas Docker) pour maximiser la perf CPU.

## Fichiers

| Fichier | Role |
|---|---|
| `install.sh` | Bootstrap : `curl ... \| sudo bash` → telecharge `setup.sh` + `.env.example` dans `~/server-tunning/`. Branche GitHub = `master`. |
| `install-os-tuning.sh` | Bootstrap **standalone** : telecharge `os-tuning.sh` dans `~/server-tunning/` et l'execute. Action via arg (`apply`/`verify`/`rollback`, defaut `apply`), overrides via env (`SWAP_SIZE`, etc.). |
| `setup.sh` | **Le coeur** (~820 lignes). Menu interactif : install, tuning, deploy, ops. Tout passe par lui. |
| `os-tuning.sh` | Script **standalone** OS tuning uniquement (sysctl reseau/BBR, FD ceilings, limits PAM + systemd, swap, governor). Sous-commandes `apply` / `verify` / `rollback`. Override par env (`SWAP_SIZE`, `NOFILE_LIMIT`, `NPROC_LIMIT`) — pas de prefixe `KYC_`. Plus complet que l'option 2 de `setup.sh` (ajoute BBR/`fq`, `tw_reuse`, buffers TCP, limits systemd, backup + rollback). |
| `.env.example` | Template de config (committe). Variables prefixees `KYC_`. |
| `.env` / `.env.prod` | Config locale (gitignored). |
| `benchmark.sh` | Charge les backends via `POST /analyze` (single + parallele), ecrit `benchmark-results.json`. IPs hardcodees en haut du fichier — a editer pour un autre environnement. |
| `update.sh` | Snippet pour re-telecharger `setup.sh` depuis GitHub (pas un script complet). |
| `BENCHMARK.md` / `README.md` | Doc. |

## Commandes

```bash
# Bootstrap one-liner (telecharge dans ~/server-tunning/)
curl -fsSL https://raw.githubusercontent.com/papesambandour/server-tunning/master/install.sh | sudo bash

# Lancer le menu (DOIT etre root)
sudo bash setup.sh --env .env

# Benchmark depuis une machine cliente
bash benchmark.sh /chemin/image.jpg 32        # ou "1 4 8 16 32 64"

# Verifier la syntaxe Bash avant commit
bash -n setup.sh && bash -n install.sh && bash -n benchmark.sh
```

Il n'y a **pas** de tests automatises, de linter, ni de build. La validation se fait en lancant `setup.sh` sur un Ubuntu (24.04 recommande, `docker run --rm -it ubuntu:24.04 bash`).

## Resolution du .env (ordre de priorite)

`setup.sh` charge le `.env` dans cet ordre, premier trouve gagne :
1. Argument `--env <path>`
2. `.env` a cote du script (`SCRIPT_DIR/.env`)
3. `/etc/kyc.env`

Charge via `set -a; source; set +a` (export auto). Sans `.env` → valeurs par defaut hardcodees dans `setup.sh` (l.59-77).

## Architecture cible (deployee par setup.sh)

```
Clients → Nginx LB (:80, least_conn) → Serveur 1 (:8000) + Serveur 2 (:8000)
                                          gunicorn + UvicornWorker, Python natif
```

- Nginx LB est **colocataire du serveur 1** (`KYC_NGINX_SERVER` = `KYC_SERVER1` par defaut).
- Deploy **rolling, zero-downtime, SANS SSH** : on se connecte physiquement sur chaque serveur et on lance l'option 5. Stopper le service fait basculer Nginx (`proxy_next_upstream`) sur l'autre serveur.

## Menu setup.sh

| Touche | Fonction | Action |
|---|---|---|
| 1 | `do_prereqs` | git, curl, build-essential, sudo, htop, jq, vim... |
| 2 | `do_tuning` | sysctl `99-perf.conf`, swap, CPU governor, ulimits |
| 3 | `do_install_python` | Python+venv, Tesseract+OCRB, clone repo, deps, verif modeles, service systemd |
| 4 | `do_install_nginx` | LB Nginx (serveur LB uniquement) |
| 5 | `do_deploy` | stop → resync remote → git pull/checkout → deps si change → verif modeles → start → smoke test `/health` |
| 6/7/8 | start / stop / restart | systemctl |
| 9 | `do_logs` | `journalctl -u $SERVICE -f` |
| t | `do_test` | curl `/health` sur serveur1, serveur2, nginx |

Chaque fonction d'install est **idempotente** : un `is_*_installed()` verifie l'etat (✓/✗ dans `show_status`) et demande confirmation avant de re-executer.

## Contrat attendu de l'app cible

`setup.sh` fait des hypotheses fortes sur le repo clone dans `$APP_DIR` :
- Entrypoint ASGI **`main:app`** (fichier `main.py`) servi par `gunicorn --worker-class uvicorn.workers.UvicornWorker`.
- `requirements.txt` a la racine.
- Endpoint **`GET /health`** renvoyant un JSON `{"status": ..., "version": ...}` — utilise par le smoke test du deploy et `do_test`.
- Endpoint **`POST /analyze`** (multipart `file=@...`) renvoyant `{processing_time_ms, is_valid, validity_score}` — utilise par `benchmark.sh`.
- Modeles attendus : `rapidocr_onnxruntime`, `onnxruntime`, et `engine/resnet18_features.onnx` (verif best-effort, non bloquante).

Modifier l'un de ces noms cote app **casse `setup.sh`** : grep `main:app`, `/health`, `/analyze` dans ce repo et adapter.

## Noms de ressources HARDCODES (PAS dans le .env)

Le prefixe `KYC_` est trompeur : beaucoup de noms d'infra sont en dur dans `setup.sh`, independamment de `KYC_SERVICE`. Si tu renommes le service, ces noms NE suivent PAS automatiquement :

| Ressource | Valeur fixe | Ligne |
|---|---|---|
| sysctl tuning | `/etc/sysctl.d/99-perf.conf` | `do_tuning` |
| limits | `/etc/security/limits.d/99-perf.conf` | `do_tuning` |
| swap | `/swap.img` | `do_tuning` |
| nginx config | `/etc/nginx/conf.d/kyc.conf`, upstream `kyc_backend` | `do_install_nginx` |
| logs gunicorn | `/var/log/kyc/{access,error}.log` | `do_install_service` |
| OCRB source | `github.com/Shreeshrii/tessdata_ocrb` | `do_install_python` |

Le service systemd, lui, suit bien `$SERVICE` (`/etc/systemd/system/$SERVICE.service`).

## Tuning CPU-bound (le coeur du projet)

**Workers gunicorn = `nproc / 2`**, borne a `[2, 24]` (`setup.sh` l.82-87 quand `KYC_WORKERS=auto`). Chaque worker OCR lance plusieurs threads internes (ONNX + OpenCV + Tesseract) ; pour eviter le *thread bomb*, le service systemd plafonne TOUS les pools de threads a 2 :

```
OMP_NUM_THREADS=2  MKL_NUM_THREADS=2  OPENBLAS_NUM_THREADS=2  BLIS_NUM_THREADS=2
ORT_NUM_THREADS=2  VECLIB_MAXIMUM_THREADS=2  NUMEXPR_NUM_THREADS=2  OMP_THREAD_LIMIT=2
```

Cible : `(nproc/2) workers × 2 threads = nproc cores` satures sans contention. (Le README/anciennes notes mentionnaient CPU/3 — la valeur reelle dans le code est **CPU/2**.)

## Detail deploy : rotation de token Git

`do_deploy` resynchronise `git remote set-url origin "$GIT_REPO"` depuis le `.env` AVANT le fetch. C'est volontaire : si le PAT GitHub change dans `.env`, le `.git/config` du repo clone garde l'ancien token et tous les `git fetch` echouent en boucle. Ne pas supprimer cette etape. Idem : `git fetch` ne redirige PAS stderr vers `/dev/null` (sinon `set -e` masque l'echec d'auth).

## Conventions de code

- `set -euo pipefail` partout.
- Helpers de log : `log` (bleu), `ok` (vert), `warn` (jaune), `fail` (rouge), `section` (cyan).
- Variables : prefixe `KYC_` dans le `.env`, sans prefixe dans le script (`APP_USER="${KYC_APP_USER:-kyc}"`).
- Idempotence obligatoire : toute nouvelle etape d'install ajoute un `is_*_installed()` + ligne dans `show_status`.
- Pas de SSH inter-serveurs, pas de Docker, Ubuntu/apt only (deadsnakes PPA pour Python < natif).
- Ne jamais hardcoder IP/port/chemin **applicatif** — utiliser les variables `KYC_`. (Les noms d'infra ci-dessus sont l'exception historique.)
- Messages console et doc en **francais**.
