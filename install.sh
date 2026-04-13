#!/bin/bash
# ============================================================
# server-tunning — Bootstrap installer
# ============================================================
# Usage : curl -fsSL https://raw.githubusercontent.com/papesambandour/server-tunning/main/install.sh | sudo bash
# ============================================================

set -euo pipefail

REPO="papesambandour/server-tunning"
BRANCH="master"
INSTALL_DIR="${HOME}/server-tunning"
BASE_URL="https://raw.githubusercontent.com/$REPO/$BRANCH"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║         server-tunning — Installation            ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# Creer le dossier
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo -e "${BLUE}[INFO]${NC}  Telechargement dans $INSTALL_DIR..."

# Telecharger les fichiers
curl -fsSL "$BASE_URL/setup.sh" -o setup.sh
curl -fsSL "$BASE_URL/.env.example" -o .env.example

chmod +x setup.sh

# Creer le .env s'il n'existe pas
if [[ ! -f .env ]]; then
    cp .env.example .env
    echo -e "${YELLOW}[WARN]${NC}  .env cree depuis .env.example — a configurer avant de lancer"
fi

echo ""
echo -e "${GREEN}[OK]${NC}    Fichiers installes dans $INSTALL_DIR"
echo ""
echo -e "  $INSTALL_DIR/"
echo -e "  ├── setup.sh        $(wc -l < setup.sh) lignes"
echo -e "  ├── .env.example    template"
echo -e "  └── .env            a configurer"
echo ""
echo -e "${BLUE}Prochaines etapes :${NC}"
echo ""
echo -e "  1. Configurer le .env :"
echo -e "     ${YELLOW}nano $INSTALL_DIR/.env${NC}"
echo ""
echo -e "  2. Lancer le menu :"
echo -e "     ${YELLOW}sudo bash $INSTALL_DIR/setup.sh --env $INSTALL_DIR/.env${NC}"
echo ""
