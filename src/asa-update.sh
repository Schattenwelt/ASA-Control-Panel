#!/usr/bin/env bash
# ASA-Update (Docker-Variante): zieht ein neueres Image (Tooling). Die eigentlichen
# Spieldateien aktualisiert das Image beim nächsten Containerstart selbst via SteamCMD.
# Wird von asa-update.service (oneshot) ausgeführt; asa.service wird vorher gestoppt.
set -euo pipefail
PANEL_DIR="${PANEL_DIR:-/opt/asa-panel}"
DOCKER_DIR="${DOCKER_DIR:-$PANEL_DIR/docker}"
ENV_FILE="$DOCKER_DIR/asa.env"

echo "[$(date '+%F %T')] Docker-Image aktualisieren ..."
cd "$DOCKER_DIR"
[ -f "$ENV_FILE" ] || echo "DATA_DIR=/opt/asa-data" > "$ENV_FILE"
docker compose --env-file "$ENV_FILE" pull
echo "[$(date '+%F %T')] Fertig. Beim nächsten Start aktualisiert der Container die Spieldateien automatisch."
