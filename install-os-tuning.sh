#!/usr/bin/env bash
# ============================================================
# install-os-tuning.sh — Bootstrap installer pour os-tuning.sh
# ============================================================
# Usage :
#   curl -fsSL https://raw.githubusercontent.com/papesambandour/server-tunning/master/install-os-tuning.sh | sudo bash
#
#   # Avec override de config et action :
#   curl -fsSL .../install-os-tuning.sh | SWAP_SIZE=8G sudo -E bash
#   curl -fsSL .../install-os-tuning.sh | sudo bash -s -- verify
# ============================================================

set -euo pipefail

REPO="papesambandour/server-tunning"
BRANCH="master"
INSTALL_DIR="${INSTALL_DIR:-${HOME}/server-tunning}"
BASE_URL="https://raw.githubusercontent.com/$REPO/$BRANCH"

# Action passee a os-tuning.sh : apply (defaut) | verify | rollback
ACTION="${1:-apply}"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

[[ $EUID -eq 0 ]] || { echo -e "${RED}[✗]${NC}  Lancer en root : curl ... | sudo bash"; exit 1; }

echo -e "${BLUE}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║       server-tunning — OS Tuning installer       ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo -e "${BLUE}[*]${NC}  Telechargement de os-tuning.sh dans $INSTALL_DIR..."
curl -fsSL "$BASE_URL/os-tuning.sh" -o os-tuning.sh
chmod +x os-tuning.sh
echo -e "${GREEN}[✓]${NC}  os-tuning.sh installe ($(wc -l < os-tuning.sh) lignes)"
echo ""

echo -e "${BLUE}[*]${NC}  Execution : os-tuning.sh ${ACTION}"
echo ""
# Propage les overrides d'env (SWAP_SIZE, NOFILE_LIMIT, NPROC_LIMIT) deja exportes.
exec bash "$INSTALL_DIR/os-tuning.sh" "$ACTION"
