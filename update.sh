#!/bin/bash
# Recupere la derniere version des fichiers de deploiement depuis GitHub.
#
# Ne recupere QUE les fichiers versionnes. Les secrets (.env, microblink/.env)
# restent a placer manuellement sur le serveur — ils ne sont pas dans le depot.
set -euo pipefail

BASE="https://raw.githubusercontent.com/papesambandour/server-tunning/master"
DEST="/root/server-tunning"

# ── Auto-mise a jour ─────────────────────────────────────────────────────────
# Sans ca, un update.sh perime ne peut jamais se reparer : il telecharge la
# derniere version de tout SAUF de lui-meme. C'est exactement ce qui est arrive
# quand microblink/ a ete ajoute — les serveurs ont continue a ne tirer que
# setup.sh, et l'option D echouait sur un docker-compose.yml introuvable.
#
# On ecrit dans un temporaire puis on remplace : bash relit le script au fil de
# son execution, l'ecraser en place ferait executer un melange des deux versions.
# Le garde-fou UPDATE_SELF_DONE evite toute boucle si le remplacement echoue.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
if [[ "${UPDATE_SELF_DONE:-}" != "1" ]]; then
    TMP="$(mktemp)"
    if curl -fsSL "$BASE/update.sh" -o "$TMP" && [[ -s "$TMP" ]] && ! cmp -s "$TMP" "$SELF"; then
        cat "$TMP" > "$SELF"          # > et non mv : preserve inode et droits
        rm -f "$TMP"
        chmod +x "$SELF"
        echo "update.sh mis a jour — relance"
        UPDATE_SELF_DONE=1 exec "$SELF" "$@"
    fi
    rm -f "$TMP"
fi

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
