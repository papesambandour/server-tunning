#!/bin/bash
# ============================================================
# AI-YAS-KYC — Menu d'installation et deploiement
# ============================================================
# Usage :
#   sudo bash setup.sh --env /path/to/.env       # avec fichier .env
#   sudo bash setup.sh --env .env                 # .env dans le meme dossier
#   sudo bash setup.sh                            # cherche .env a cote du script
# ============================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${BLUE}[INFO]${NC}  $1"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
fail()    { echo -e "${RED}[FAIL]${NC}  $1"; }
section() { echo -e "\n${CYAN}── $1 ──${NC}"; }

# ── Charger le .env ──────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE=""

# Parse --env argument
while [[ $# -gt 0 ]]; do
    case $1 in
        --env) ENV_FILE="$2"; shift 2 ;;
        *)     shift ;;
    esac
done

# Chercher le .env : argument > a cote du script > /etc/kyc.env
if [[ -z "$ENV_FILE" ]]; then
    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        ENV_FILE="$SCRIPT_DIR/.env"
    elif [[ -f "/etc/kyc.env" ]]; then
        ENV_FILE="/etc/kyc.env"
    fi
fi

if [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then
    log "Chargement de $ENV_FILE"
    set -a
    source "$ENV_FILE"
    set +a
else
    warn "Pas de .env trouve — valeurs par defaut utilisees"
    warn "Creer un .env avec : cp .env.example .env && nano .env"
fi

# ── Config (valeurs du .env ou defauts) ──────────────────────
APP_USER="${KYC_APP_USER:-kyc}"
APP_DIR="${KYC_APP_DIR:-/opt/kyc}"
VENV_DIR="$APP_DIR/.venv"
SERVICE="${KYC_SERVICE:-kyc}"
GIT_REPO="${KYC_GIT_REPO:-}"
GIT_BRANCH="${KYC_GIT_BRANCH:-main}"
PYTHON_VERSION="${KYC_PYTHON_VERSION:-python3.9}"
BIND_HOST="${KYC_BIND_HOST:-0.0.0.0}"
BIND_PORT="${KYC_BIND_PORT:-8000}"

SERVER1="${KYC_SERVER1:-10.0.92.66}"
SERVER2="${KYC_SERVER2:-10.0.92.67}"
NGINX_SERVER="${KYC_NGINX_SERVER:-$SERVER1}"

GUNICORN_WORKERS="${KYC_WORKERS:-auto}"
GUNICORN_TIMEOUT="${KYC_TIMEOUT:-120}"
GUNICORN_MAX_REQUESTS="${KYC_MAX_REQUESTS:-1000}"

SWAP_SIZE="${KYC_SWAP_SIZE:-4G}"

# Auto-calcul workers si "auto"
if [[ "$GUNICORN_WORKERS" == "auto" ]]; then
    CPU_COUNT=$(nproc)
    GUNICORN_WORKERS=$((CPU_COUNT / 3))
    [[ $GUNICORN_WORKERS -lt 2 ]] && GUNICORN_WORKERS=2
    [[ $GUNICORN_WORKERS -gt 12 ]] && GUNICORN_WORKERS=12
fi

# Detecter le serveur actuel
CURRENT_IP=$(hostname -I | awk '{print $1}')

# ── Checks d'etat ────────────────────────────────────────────
is_prereqs_installed()  { command -v git &>/dev/null && command -v curl &>/dev/null && command -v make &>/dev/null; }
is_python_installed()   { [[ -f "$VENV_DIR/bin/python" ]]; }
is_app_installed()      { [[ -f "$APP_DIR/main.py" ]]; }
is_service_installed()  { systemctl list-unit-files | grep -q "$SERVICE.service"; }
is_service_running()    { systemctl is-active --quiet $SERVICE 2>/dev/null; }
is_nginx_installed()    { command -v nginx &>/dev/null; }
is_nginx_configured()   { [[ -f /etc/nginx/conf.d/kyc.conf ]]; }
is_nginx_running()      { systemctl is-active --quiet nginx 2>/dev/null; }
is_tuning_applied()     { [[ -f /etc/sysctl.d/99-perf.conf ]]; }
is_ocrb_installed()     { tesseract --list-langs 2>&1 | grep -q ocrb 2>/dev/null; }

status_icon() {
    if $1; then echo -e "${GREEN}✓${NC}"; else echo -e "${RED}✗${NC}"; fi
}

# ── Header ───────────────────────────────────────────────────
show_header() {
    clear
    echo -e "${CYAN}"
    echo "  ╔══════════════════════════════════════════════════╗"
    echo "  ║         Server Setup & Deploy                    ║"
    echo "  ╠══════════════════════════════════════════════════╣"
    echo -e "  ║  Serveur : ${BOLD}$CURRENT_IP${NC}${CYAN}                          ║"
    echo -e "  ║  App 1   : $SERVER1:$BIND_PORT                       ║"
    echo -e "  ║  App 2   : $SERVER2:$BIND_PORT                       ║"
    echo -e "  ║  Nginx   : $NGINX_SERVER                       ║"
    echo "  ╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ── Status ───────────────────────────────────────────────────
show_status() {
    echo -e "  ${BOLD}Etat du serveur $CURRENT_IP :${NC}"
    echo ""
    echo -e "    $(status_icon is_prereqs_installed)  Prerequis (git, curl, build-essential)"
    echo -e "    $(status_icon is_tuning_applied)  OS Tuning (sysctl, ulimits)"
    echo -e "    $(status_icon is_python_installed)  $PYTHON_VERSION + venv"
    echo -e "    $(status_icon is_ocrb_installed)  Tesseract + OCRB"
    echo -e "    $(status_icon is_app_installed)  Code app ($APP_DIR)"
    echo -e "    $(status_icon is_service_installed)  Service systemd ($SERVICE)"

    if is_service_installed; then
        if is_service_running; then
            WORKERS=$(pgrep -c -f "gunicorn.*main:app" 2>/dev/null || echo "0")
            echo -e "    ${GREEN}✓${NC}  Service actif ($WORKERS workers)"
        else
            echo -e "    ${RED}✗${NC}  Service arrete"
        fi
    fi

    if [[ "$CURRENT_IP" == "$NGINX_SERVER" ]] || is_nginx_installed; then
        echo ""
        echo -e "    $(status_icon is_nginx_installed)  Nginx installe"
        echo -e "    $(status_icon is_nginx_configured)  Nginx configure (LB)"
        echo -e "    $(status_icon is_nginx_running)  Nginx actif"
    fi
    echo ""
}

# ════════════════════════════════════════════════════════════
# INSTALLATION
# ════════════════════════════════════════════════════════════

do_prereqs() {
    section "Prerequis de base"

    if is_prereqs_installed; then
        ok "Prerequis deja installes"
        echo -e "    git     : $(git --version 2>/dev/null | cut -d' ' -f3)"
        echo -e "    curl    : $(curl --version 2>/dev/null | head -1 | cut -d' ' -f2)"
        echo -e "    make    : $(make --version 2>/dev/null | head -1)"
        read -p "  Reinstaller / mettre a jour ? (o/N) " -n 1 -r; echo
        [[ ! $REPLY =~ ^[Oo]$ ]] && return
    fi

    log "Mise a jour des paquets..."
    apt-get update -qq

    log "Installation des prerequis..."
    apt-get install -y --no-install-recommends \
        sudo \
        git \
        curl \
        wget \
        build-essential \
        make \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release \
        unzip \
        htop \
        iotop \
        net-tools \
        jq \
        tree \
        vim \
        > /dev/null

    ok "Prerequis installes"
    echo ""
    echo -e "    git             : $(git --version 2>/dev/null | cut -d' ' -f3)"
    echo -e "    curl            : $(curl --version 2>/dev/null | head -1 | cut -d' ' -f2)"
    echo -e "    make            : $(make --version 2>/dev/null | head -1 | awk '{print $NF}')"
    echo -e "    jq              : $(jq --version 2>/dev/null)"
    echo -e "    build-essential : OK"
    echo -e "    htop/iotop      : OK (monitoring)"
}

do_tuning() {
    section "OS Tuning"
    if is_tuning_applied; then
        ok "Tuning deja applique (/etc/sysctl.d/99-perf.conf existe)"
        read -p "  Re-appliquer ? (o/N) " -n 1 -r; echo
        [[ ! $REPLY =~ ^[Oo]$ ]] && return
    fi

    log "Application du tuning kernel..."

    cat > /etc/sysctl.d/99-perf.conf <<'SYSCTL'
vm.swappiness=10
vm.dirty_ratio=15
vm.dirty_background_ratio=5
vm.vfs_cache_pressure=50
vm.overcommit_memory=0
fs.file-max=2097152
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512
net.core.somaxconn=65535
net.core.netdev_max_backlog=16384
net.ipv4.tcp_max_syn_backlog=65535
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.ipv4.ip_local_port_range=1024 65535
kernel.pid_max=4194304
kernel.threads-max=4194304
SYSCTL

    sysctl --system > /dev/null 2>&1

    cat > /etc/security/limits.d/99-perf.conf <<'LIMITS'
*    soft nofile 1048576
*    hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
*    soft nproc  unlimited
*    hard nproc  unlimited
LIMITS

    grep -q "pam_limits.so" /etc/pam.d/common-session 2>/dev/null || \
        echo "session required pam_limits.so" >> /etc/pam.d/common-session

    # Swap securite
    if ! swapon --show | grep -q .; then
        log "Creation swap $SWAP_SIZE..."
        fallocate -l $SWAP_SIZE /swap.img 2>/dev/null || dd if=/dev/zero of=/swap.img bs=1M count=$((${SWAP_SIZE%G} * 1024)) 2>/dev/null
        chmod 600 /swap.img && mkswap /swap.img > /dev/null && swapon /swap.img
        grep -q "/swap.img" /etc/fstab || echo "/swap.img none swap sw 0 0" >> /etc/fstab
    fi

    # CPU governor performance (ignore sur les VMs sans cpufreq)
    if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
        for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo "performance" > "$cpu" 2>/dev/null || true
        done
        ok "CPU governor = performance"
    else
        ok "cpufreq non disponible (VM) — gere par l'hyperviseur"
    fi

    ok "Tuning applique"
}

do_install_python() {
    section "Installation Python + App"

    if is_python_installed && is_ocrb_installed; then
        ok "Python + Tesseract OCRB deja installes"
        read -p "  Reinstaller ? (o/N) " -n 1 -r; echo
        [[ ! $REPLY =~ ^[Oo]$ ]] && return
    fi

    log "Installation des paquets systeme..."
    apt-get update -qq

    # Sur Ubuntu 24.04, Python 3.9/3.11 n'est pas natif — utiliser deadsnakes PPA
    if ! apt-cache show $PYTHON_VERSION 2>/dev/null | grep -q "Package:"; then
        log "$PYTHON_VERSION non disponible — ajout du PPA deadsnakes..."
        apt-get install -y --no-install-recommends software-properties-common > /dev/null
        add-apt-repository -y ppa:deadsnakes/ppa 2>/dev/null
        apt-get update -qq
    fi

    apt-get install -y --no-install-recommends \
        $PYTHON_VERSION ${PYTHON_VERSION}-venv ${PYTHON_VERSION}-dev python3-pip \
        tesseract-ocr tesseract-ocr-eng tesseract-ocr-fra \
        libgl1 libglib2.0-0 git curl build-essential > /dev/null
    ok "Paquets systeme OK ($($PYTHON_VERSION --version 2>&1), $(tesseract --version 2>&1 | head -1))"

    # OCRB
    if ! is_ocrb_installed; then
        log "Installation Tesseract OCRB..."
        cd /tmp && git clone --depth 1 https://github.com/Shreeshrii/tessdata_ocrb.git 2>/dev/null
        TESSDATA=$(find /usr/share/tesseract-ocr -name tessdata -type d | head -1)
        cp tessdata_ocrb/ocrb.traineddata "$TESSDATA/" && rm -rf tessdata_ocrb
        ok "OCRB installe"
    fi

    # Utilisateur
    id "$APP_USER" &>/dev/null || useradd -r -s /bin/bash -m -d /home/$APP_USER $APP_USER

    # Clone du repo (si pas deja fait)
    if [[ ! -d "$APP_DIR/.git" ]]; then
        if [[ -n "$GIT_REPO" ]]; then
            log "Clone du repo dans $APP_DIR..."
            if [[ -d "$APP_DIR" ]]; then
                rm -rf "$APP_DIR"
            fi
            git clone -b "$GIT_BRANCH" "$GIT_REPO" "$APP_DIR"
            ok "Repo clone ($GIT_BRANCH)"
        else
            mkdir -p $APP_DIR
            warn "Pas de KYC_GIT_REPO dans le .env — code a copier manuellement dans $APP_DIR"
        fi
    else
        ok "Repo deja clone dans $APP_DIR"
    fi
    chown -R $APP_USER:$APP_USER $APP_DIR

    # Venv
    if [[ ! -f "$VENV_DIR/bin/python" ]]; then
        log "Creation du venv..."
        $PYTHON_VERSION -m venv $VENV_DIR
    fi

    $VENV_DIR/bin/pip install --upgrade pip -q

    if [[ -f "$APP_DIR/requirements.txt" ]]; then
        log "Installation des deps Python..."
        $VENV_DIR/bin/pip install --no-cache-dir -r $APP_DIR/requirements.txt -q
        ok "Deps Python OK"
    else
        warn "Pas de requirements.txt — deployer le code d'abord (menu 5)"
    fi

    # Verification modeles
    log "Verification des modeles..."
    $VENV_DIR/bin/python -c "
import onnxruntime as ort; print(f'ONNX Runtime {ort.__version__} OK')
from rapidocr_onnxruntime import RapidOCR; RapidOCR(); print('RapidOCR OK')
import os
onnx_path = os.path.join('$APP_DIR', 'engine', 'resnet18_features.onnx')
if os.path.exists(onnx_path):
    sess = ort.InferenceSession(onnx_path, providers=['CPUExecutionProvider'])
    print('ResNet18 ONNX OK')
else:
    print(f'WARN: {onnx_path} non trouve')
" 2>/dev/null || warn "Modeles non verifies"

    # Donner tous les droits au user app (venv, cache, code)
    chown -R $APP_USER:$APP_USER $APP_DIR
    ok "Droits $APP_USER appliques sur $APP_DIR"

    # Service systemd
    do_install_service
    ok "Installation Python terminee"
}

do_install_service() {
    log "Creation du service systemd..."

    mkdir -p /var/log/kyc && chown $APP_USER:$APP_USER /var/log/kyc

    cat > /etc/systemd/system/$SERVICE.service <<EOF
[Unit]
Description=AI-YAS-KYC — API verification identite
After=network.target

[Service]
Type=simple
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$APP_DIR
Environment="PATH=$VENV_DIR/bin:/usr/local/bin:/usr/bin"
Environment="OMP_NUM_THREADS=2"
Environment="MKL_NUM_THREADS=2"
Environment="ORT_NUM_THREADS=2"
Environment="OMP_THREAD_LIMIT=2"

ExecStart=$VENV_DIR/bin/gunicorn main:app \\
    --worker-class uvicorn.workers.UvicornWorker \\
    --workers $GUNICORN_WORKERS \\
    --bind $BIND_HOST:$BIND_PORT \\
    --timeout $GUNICORN_TIMEOUT \\
    --graceful-timeout 30 \\
    --keep-alive 5 \\
    --max-requests $GUNICORN_MAX_REQUESTS \\
    --max-requests-jitter 50 \\
    --access-logfile /var/log/kyc/access.log \\
    --error-logfile /var/log/kyc/error.log

Restart=always
RestartSec=5
LimitNOFILE=1048576
ProtectSystem=full
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable $SERVICE -q
    systemctl restart $SERVICE 2>/dev/null || systemctl start $SERVICE

    # Attendre que le service demarre
    local RETRIES=0
    while [[ $RETRIES -lt 15 ]]; do
        if systemctl is-active --quiet $SERVICE 2>/dev/null; then
            ok "Service $SERVICE.service demarre ($GUNICORN_WORKERS workers, port $BIND_PORT)"
            return
        fi
        RETRIES=$((RETRIES + 1))
        sleep 1
    done
    warn "Service cree mais pas encore actif — verifier : journalctl -u $SERVICE -n 20"
}

do_install_nginx() {
    section "Installation Nginx (Load Balancer)"

    if is_nginx_configured; then
        ok "Nginx deja configure"
        read -p "  Reconfigurer ? (o/N) " -n 1 -r; echo
        [[ ! $REPLY =~ ^[Oo]$ ]] && return
    fi

    if ! is_nginx_installed; then
        log "Installation Nginx..."
        apt-get update -qq && apt-get install -y --no-install-recommends nginx > /dev/null
    fi

    CPU_COUNT=$(nproc)

    cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes $CPU_COUNT;
pid /run/nginx.pid;
worker_rlimit_nofile 65535;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    types_hash_max_size 2048;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    client_body_timeout 60s;
    client_header_timeout 15s;
    send_timeout 60s;
    keepalive_timeout 65s;
    keepalive_requests 1000;

    proxy_connect_timeout 10s;
    proxy_send_timeout 120s;
    proxy_read_timeout 120s;

    client_max_body_size 20m;

    proxy_buffer_size 16k;
    proxy_buffers 8 32k;
    proxy_busy_buffers_size 64k;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 4;
    gzip_min_length 256;
    gzip_types application/json text/plain;

    log_format main '\$remote_addr [\$time_local] "\$request" \$status '
                    'rt=\$request_time urt=\$upstream_response_time';
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;

    include /etc/nginx/conf.d/*.conf;
}
EOF

    cat > /etc/nginx/conf.d/kyc.conf <<EOF
upstream kyc_backend {
    least_conn;
    server $SERVER1:$BIND_PORT max_fails=3 fail_timeout=30s;
    server $SERVER2:$BIND_PORT max_fails=3 fail_timeout=30s;
    keepalive 32;
}

server {
    listen 80;
    server_name _;

    location /nginx-health {
        access_log off;
        return 200 '{"status":"ok","service":"nginx-lb"}';
        add_header Content-Type application/json;
    }

    location /nginx-status {
        stub_status on;
        access_log off;
        allow 10.0.0.0/8;
        allow 127.0.0.1;
        deny all;
    }

    location / {
        proxy_pass http://kyc_backend;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Connection "";
        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 2;
        proxy_next_upstream_timeout 30s;
    }
}
EOF

    nginx -t 2>&1 || { fail "Config Nginx invalide"; return; }
    systemctl enable nginx -q
    systemctl restart nginx
    ok "Nginx configure et demarre (LB least_conn → $SERVER1 + $SERVER2)"
}

# ════════════════════════════════════════════════════════════
# DEPLOIEMENT ZERO-DOWNTIME
# ════════════════════════════════════════════════════════════

do_deploy() {
    section "Deploiement local (ce serveur)"

    if [[ ! -d "$APP_DIR/.git" ]]; then
        fail "$APP_DIR n'est pas un repo git"
        return
    fi

    DEPLOY_START=$(date +%s)
    PREV=$(cd $APP_DIR && git rev-parse --short HEAD)
    PREV_MSG=$(cd $APP_DIR && git log -1 --pretty=format:"%s")

    echo -e "  Serveur  : $CURRENT_IP"
    echo -e "  Commit   : $PREV ($PREV_MSG)"
    echo ""

    # Choix de la branch/tag
    echo -e "  ${BOLD}Source :${NC}"
    echo -e "    ${CYAN}1${NC}  $GIT_BRANCH (defaut .env)"
    echo -e "    ${CYAN}2${NC}  Autre branche"
    echo -e "    ${CYAN}3${NC}  Tag specifique"
    echo ""
    read -p "  Choix (1/2/3) : " -n 1 -r SRC_CHOICE; echo

    BRANCH="$GIT_BRANCH"
    case $SRC_CHOICE in
        2) read -p "  Nom de la branche : " BRANCH ;;
        3) read -p "  Nom du tag : " TAG_NAME; BRANCH="" ;;
    esac

    read -p "  Confirmer le deploiement ? (o/N) " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Oo]$ ]] && return

    # Stop le service (nginx bascule sur l'autre serveur)
    log "Arret du service (nginx bascule le trafic sur l'autre serveur)..."
    systemctl stop $SERVICE
    ok "Service arrete — trafic bascule sur l'autre serveur"

    # Git pull
    log "Git fetch + pull..."
    cd $APP_DIR
    git fetch --all --prune -q 2>/dev/null

    if [[ -n "${TAG_NAME:-}" ]]; then
        git checkout "$TAG_NAME" -q 2>/dev/null
    else
        git checkout "$BRANCH" -q 2>/dev/null
        git pull origin "$BRANCH" -q 2>/dev/null
    fi

    NEW=$(git rev-parse --short HEAD)
    NEW_MSG=$(git log -1 --pretty=format:"%s")

    if [[ "$PREV" == "$NEW" ]]; then
        warn "Pas de nouveau commit ($PREV)"
    else
        ok "Code : $PREV → $NEW ($NEW_MSG)"
    fi

    # Deps si changees
    if [[ -f requirements.txt ]]; then
        if [[ "$PREV" != "$NEW" ]] && git diff "$PREV" "$NEW" -- requirements.txt 2>/dev/null | grep -q .; then
            log "requirements.txt a change — mise a jour des deps..."
            $VENV_DIR/bin/pip install --no-cache-dir -r requirements.txt -q
            ok "Deps mises a jour"
        else
            ok "Deps inchangees"
        fi
    fi

    # Modeles
    log "Verification des modeles..."
    $VENV_DIR/bin/python -c "
from rapidocr_onnxruntime import RapidOCR; RapidOCR()
import onnxruntime as ort, os
onnx_path = os.path.join('$APP_DIR', 'engine', 'resnet18_features.onnx')
if os.path.exists(onnx_path):
    ort.InferenceSession(onnx_path, providers=['CPUExecutionProvider'])
print('OK')
" 2>/dev/null && ok "Modeles OK" || warn "Verifier les modeles"

    # Remettre les droits au user app
    chown -R $APP_USER:$APP_USER $APP_DIR

    # Redemarrer
    log "Demarrage du service..."
    systemctl start $SERVICE

    # Attendre que le service reponde
    local RETRIES=0
    while [[ $RETRIES -lt 30 ]]; do
        curl -s --max-time 2 http://127.0.0.1:$BIND_PORT/health > /dev/null 2>&1 && break
        RETRIES=$((RETRIES + 1))
        sleep 1
    done

    if [[ $RETRIES -ge 30 ]]; then
        fail "Service ne repond pas apres 30s !"
        fail "Verifier : sudo journalctl -u $SERVICE -n 50"
        fail "Rollback : cd $APP_DIR && git checkout $PREV && sudo systemctl start $SERVICE"
        return
    fi

    # Health check
    HEALTH=$(curl -s --max-time 5 http://127.0.0.1:$BIND_PORT/health)
    VERSION=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")

    DEPLOY_END=$(date +%s)
    DURATION=$((DEPLOY_END - DEPLOY_START))
    WORKERS=$(pgrep -c -f "gunicorn.*main:app" 2>/dev/null || echo "?")

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Deploy reussi en ${DURATION}s                              ${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Version  : $VERSION"
    echo -e "  Commit   : $NEW ($NEW_MSG)"
    echo -e "  Workers  : $WORKERS"
    echo -e "  Serveur  : $CURRENT_IP"
    echo ""
    # Determiner l'autre serveur
    if [[ "$CURRENT_IP" == "$SERVER1" ]]; then
        OTHER_SERVER="$SERVER2"
    else
        OTHER_SERVER="$SERVER1"
    fi
    echo -e "  ${YELLOW}→ Deployer maintenant sur l'autre serveur ($OTHER_SERVER) !${NC}"
    echo -e "  ${YELLOW}  Via Segura : connect user@$OTHER_SERVER${NC}"
    echo -e "  ${YELLOW}  Puis : sudo bash $APP_DIR/setup.sh --env $APP_DIR/.env${NC}"
}

# ════════════════════════════════════════════════════════════
# OPERATIONS
# ════════════════════════════════════════════════════════════

do_start()   { systemctl start $SERVICE && ok "Service demarre"; }
do_stop()    { systemctl stop $SERVICE && ok "Service arrete"; }
do_restart() { systemctl restart $SERVICE && ok "Service redemarre"; }
do_logs()    { journalctl -u $SERVICE -f --no-pager; }
do_test() {
    section "Test des backends"
    for SERVER in $SERVER1 $SERVER2; do
        HEALTH=$(curl -s --max-time 5 http://$SERVER:$BIND_PORT/health 2>/dev/null)
        if echo "$HEALTH" | grep -q '"status"'; then
            VERSION=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null)
            ok "$SERVER → v$VERSION"
        else
            fail "$SERVER → pas de reponse"
        fi
    done
    if is_nginx_running; then
        HEALTH=$(curl -s --max-time 5 http://$NGINX_SERVER/health 2>/dev/null)
        if echo "$HEALTH" | grep -q '"status"'; then
            ok "Nginx LB → OK (via $NGINX_SERVER)"
        else
            fail "Nginx LB → pas de reponse"
        fi
    fi
}

# ════════════════════════════════════════════════════════════
# MENU PRINCIPAL
# ════════════════════════════════════════════════════════════

[[ $EUID -ne 0 ]] && { echo -e "${RED}Lance ce script en root : sudo bash $0${NC}"; exit 1; }

while true; do
    show_header
    show_status

    echo -e "  ${BOLD}── Installation ──${NC}"
    echo -e "    ${CYAN}1${NC}  Prerequis (git, curl, build-essential, htop, jq...)"
    echo -e "    ${CYAN}2${NC}  OS Tuning (kernel, swap, CPU governor)"
    echo -e "    ${CYAN}3${NC}  Python + App + Service systemd"
    echo -e "    ${CYAN}4${NC}  Nginx Load Balancer (serveur LB uniquement)"
    echo ""
    echo -e "  ${BOLD}── Deploiement ──${NC}"
    echo -e "    ${CYAN}5${NC}  Deploy (git pull + restart)"
    echo ""
    echo -e "  ${BOLD}── Operations ──${NC}"
    echo -e "    ${CYAN}6${NC}  Start service"
    echo -e "    ${CYAN}7${NC}  Stop service"
    echo -e "    ${CYAN}8${NC}  Restart service"
    echo -e "    ${CYAN}9${NC}  Logs (live)"
    echo -e "    ${CYAN}t${NC}  Test tous les backends"
    echo ""
    echo -e "    ${CYAN}0${NC}  Quitter"
    echo ""

    read -p "  Choix : " -n 1 -r CHOICE; echo
    echo ""

    case $CHOICE in
        1) do_prereqs ;;
        2) do_tuning ;;
        3) do_install_python ;;
        4) do_install_nginx ;;
        5) do_deploy ;;
        6) do_start ;;
        7) do_stop ;;
        8) do_restart ;;
        9) do_logs ;;
        t|T) do_test ;;
        0) echo -e "${GREEN}Bye.${NC}"; exit 0 ;;
        *) warn "Choix invalide" ;;
    esac

    echo ""
    read -p "  Appuie sur Entree pour revenir au menu..." -r
done
