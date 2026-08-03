#!/bin/bash
# Recupere la derniere version des fichiers de deploiement depuis GitHub.
#
# Ne recupere QUE les fichiers versionnes. Les secrets (.env, microblink/.env)
# restent a placer manuellement sur le serveur — ils ne sont pas dans le depot.
set -euo pipefail

BASE="https://raw.githubusercontent.com/papesambandour/server-tunning/master"
DEST="/root/server-tunning"

mkdir -p "$DEST/microblink"

curl -fsSL "$BASE/setup.sh"                        -o "$DEST/setup.sh"
chmod +x "$DEST/setup.sh"

# Stack Microblink : compose + gabarit de config.
curl -fsSL "$BASE/microblink/docker-compose.yml"   -o "$DEST/microblink/docker-compose.yml"
curl -fsSL "$BASE/microblink/.env.example"         -o "$DEST/microblink/.env.example"

echo "Fichiers a jour dans $DEST"
if [[ ! -f "$DEST/microblink/.env" ]]; then
    echo ""
    echo "  microblink/.env absent — a creer AVANT de deployer Microblink :"
    echo "    cp $DEST/microblink/.env.example $DEST/microblink/.env"
    echo "    vi $DEST/microblink/.env      # renseigner LICENSEE et LICENSE_KEY"
    echo "    chmod 600 $DEST/microblink/.env"
fi
