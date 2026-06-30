#!/usr/bin/env bash
#
# os-tuning.sh — OS performance & network tuning
# Targets: high connection throughput, fewer TCP RST/EOF, large FD ceilings
# Tested on: Ubuntu 22.04/24.04, Debian 12 (systemd + PAM)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config (override via env)
# ---------------------------------------------------------------------------
SWAP_SIZE="${SWAP_SIZE:-4G}"
NOFILE_LIMIT="${NOFILE_LIMIT:-1048576}"
NPROC_LIMIT="${NPROC_LIMIT:-256000}"     # finite is safer than 'unlimited'
SYSCTL_FILE="/etc/sysctl.d/99-perf.conf"
LIMITS_FILE="/etc/security/limits.d/99-perf.conf"
BACKUP_DIR="/var/backups/os-tuning-$(date +%Y%m%d-%H%M%S)"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_YEL='\033[0;33m'; C_BLU='\033[0;34m'; C_RST='\033[0m'
log()     { echo -e "${C_BLU}[*]${C_RST} $*"; }
ok()      { echo -e "${C_GREEN}[✓]${C_RST} $*"; }
warn()    { echo -e "${C_YEL}[!]${C_RST} $*"; }
err()     { echo -e "${C_RED}[✗]${C_RST} $*" >&2; }
section() { echo; echo -e "${C_BLU}=== $* ===${C_RST}"; }

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
require_root() {
    [[ $EUID -eq 0 ]] || { err "Lancer en root (sudo)"; exit 1; }
}

is_tuning_applied() {
    [[ -f "$SYSCTL_FILE" ]]
}

backup_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$f" "$BACKUP_DIR/"
    log "Backup: $f -> $BACKUP_DIR/"
}

# ---------------------------------------------------------------------------
# BBR / TCP congestion control detection
# ---------------------------------------------------------------------------
detect_bbr() {
    if modprobe tcp_bbr 2>/dev/null && \
       grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        echo "bbr"
    else
        echo "cubic"
    fi
}

# ---------------------------------------------------------------------------
# Main tuning
# ---------------------------------------------------------------------------
do_tuning() {
    section "OS Tuning"

    if is_tuning_applied; then
        ok "Tuning deja applique ($SYSCTL_FILE existe)"
        read -p "  Re-appliquer ? (o/N) " -n 1 -r; echo
        [[ ! $REPLY =~ ^[Oo]$ ]] && return 0
    fi

    backup_file "$SYSCTL_FILE"
    backup_file "$LIMITS_FILE"

    local CC; CC="$(detect_bbr)"
    log "Congestion control choisi : $CC"

    # --- 1. Raise kernel FD ceiling FIRST (limits.conf can't exceed fs.nr_open) ---
    log "Application du tuning kernel..."
    cat > "$SYSCTL_FILE" <<SYSCTL
# ---- Memory ----
vm.swappiness=10
vm.dirty_ratio=15
vm.dirty_background_ratio=5
vm.vfs_cache_pressure=50
vm.overcommit_memory=0
vm.max_map_count=262144

# ---- File handles ----
fs.file-max=2097152
fs.nr_open=${NOFILE_LIMIT}
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512

# ---- Network: queues & backlogs ----
net.core.somaxconn=65535
net.core.netdev_max_backlog=16384
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_max_syn_backlog=65535
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216

# ---- Network: connection lifecycle (reduces RST/EOF under churn) ----
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_max_tw_buckets=2000000
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_mtu_probing=1
net.ipv4.ip_local_port_range=1024 65535

# ---- Network: congestion control ----
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=${CC}

# ---- Process / thread ceilings ----
kernel.pid_max=4194304
kernel.threads-max=4194304
SYSCTL

    sysctl --system > /dev/null 2>&1 && ok "sysctl applique" || warn "sysctl: certains parametres ignores"

    # --- 2. PAM limits (login sessions) ---
    cat > "$LIMITS_FILE" <<LIMITS
*    soft nofile ${NOFILE_LIMIT}
*    hard nofile ${NOFILE_LIMIT}
root soft nofile ${NOFILE_LIMIT}
root hard nofile ${NOFILE_LIMIT}
*    soft nproc  ${NPROC_LIMIT}
*    hard nproc  ${NPROC_LIMIT}
root soft nproc  ${NPROC_LIMIT}
root hard nproc  ${NPROC_LIMIT}
LIMITS
    ok "limits.conf ecrit (nofile=${NOFILE_LIMIT}, nproc=${NPROC_LIMIT})"

    # --- 3. Ensure pam_limits is loaded ---
    for f in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
        [[ -f "$f" ]] || continue
        grep -q "pam_limits.so" "$f" || echo "session required pam_limits.so" >> "$f"
    done

    # --- 4. systemd global limits (services IGNORE limits.conf) ---
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-perf.conf <<SYSTEMD
[Manager]
DefaultLimitNOFILE=${NOFILE_LIMIT}
DefaultLimitNPROC=${NPROC_LIMIT}
SYSTEMD
    mkdir -p /etc/systemd/user.conf.d
    cat > /etc/systemd/user.conf.d/99-perf.conf <<SYSTEMD
[Manager]
DefaultLimitNOFILE=${NOFILE_LIMIT}
DefaultLimitNPROC=${NPROC_LIMIT}
SYSTEMD
    systemctl daemon-reexec 2>/dev/null || true
    ok "Limites systemd appliquees (daemon-reexec requis / reboot pour effet complet)"

    # --- 5. Swap safety net ---
    if ! swapon --show | grep -q .; then
        log "Creation swap $SWAP_SIZE..."
        if fallocate -l "$SWAP_SIZE" /swap.img 2>/dev/null; then :; else
            dd if=/dev/zero of=/swap.img bs=1M count=$(( ${SWAP_SIZE%G} * 1024 )) status=none
        fi
        chmod 600 /swap.img
        mkswap /swap.img > /dev/null
        swapon /swap.img
        grep -q "/swap.img" /etc/fstab || echo "/swap.img none swap sw 0 0" >> /etc/fstab
        ok "Swap $SWAP_SIZE actif"
    else
        ok "Swap deja present"
    fi

    # --- 6. CPU governor (skip on cpufreq-less VMs) ---
    if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
        for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo "performance" > "$cpu" 2>/dev/null || true
        done
        ok "CPU governor = performance"
    else
        ok "cpufreq non disponible (VM) — gere par l'hyperviseur"
    fi

    ok "Tuning applique"
    warn "Effet complet : deconnexion/reconnexion (login) + 'systemctl restart' des services."
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
verify_tuning() {
    section "Verification"
    echo "  ulimit -n (soft) : $(ulimit -n)"
    echo "  ulimit -Hn (hard): $(ulimit -Hn)"
    echo "  fs.nr_open       : $(sysctl -n fs.nr_open)"
    echo "  somaxconn        : $(sysctl -n net.core.somaxconn)"
    echo "  congestion ctrl  : $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo "  qdisc            : $(sysctl -n net.core.default_qdisc)"
    echo "  tw_reuse         : $(sysctl -n net.ipv4.tcp_tw_reuse)"
    echo "  swap             : $(swapon --show --noheadings | awk '{print $1, $3}' | tr '\n' ' ')"
}

# ---------------------------------------------------------------------------
# Rollback
# ---------------------------------------------------------------------------
do_rollback() {
    section "Rollback"
    rm -f "$SYSCTL_FILE" "$LIMITS_FILE" \
          /etc/systemd/system.conf.d/99-perf.conf \
          /etc/systemd/user.conf.d/99-perf.conf
    sysctl --system > /dev/null 2>&1 || true
    systemctl daemon-reexec 2>/dev/null || true
    ok "Fichiers de tuning supprimes (swap/governor laisses intacts)"
    warn "Reboot recommande pour revenir aux defaults kernel."
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
main() {
    require_root
    case "${1:-apply}" in
        apply)    do_tuning; verify_tuning ;;
        verify)   verify_tuning ;;
        rollback) do_rollback ;;
        *) echo "Usage: $0 {apply|verify|rollback}"; exit 1 ;;
    esac
}

main "$@"
