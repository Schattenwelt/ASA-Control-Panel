#!/usr/bin/env bash
# Aktualisiert den ASA-Dedicated-Server via SteamCMD (AppID 2430930).
# ASA ist eine Windows-Anwendung -> SteamCMD muss die WINDOWS-Depots laden
# (+@sSteamCmdForcePlatformType windows), sonst kommt ArkAscendedServer.exe nicht.
# Wird vom Panel über asa-update.service (oneshot) aufgerufen; der Server wird
# durch die Service-Definition vorher gestoppt.
set -euo pipefail

APPID=2430930
INSTALL_DIR="${INSTALL_DIR:-$HOME/asaserver}"
STEAMCMD="${STEAMCMD:-/usr/games/steamcmd}"
BACKUP_DIR="$HOME/backups"
KEEP=7

echo "[$(date '+%F %T')] Update gestartet."

# --- Spielstände sichern -----------------------------------------------------
SAVED="$INSTALL_DIR/ShooterGame/Saved"
if [ -d "$SAVED" ]; then
    mkdir -p "$BACKUP_DIR"
    TS="$(date +%Y%m%d-%H%M%S)"
    echo "Sichere Spielstände nach saved-$TS.tar.gz ..."
    tar czf "$BACKUP_DIR/saved-$TS.tar.gz" -C "$INSTALL_DIR/ShooterGame" Saved || \
        echo "WARN: Backup nicht vollständig."
    ls -1t "$BACKUP_DIR"/saved-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | \
        xargs -r rm -f
fi

# --- Update ------------------------------------------------------------------
# Auf die Binary prüfen statt auf den Exit-Code: SteamCMD kann bei leerem Cache
# ("Missing configuration") trotzdem 0 liefern. Bis zu 5 Versuche.
echo "Führe SteamCMD-Update aus (AppID $APPID, Windows-Depots) ..."
ASA_BIN="$INSTALL_DIR/ShooterGame/Binaries/Win64/ArkAscendedServer.exe"
tries=0
while [ "$tries" -lt 5 ]; do
    tries=$((tries+1))
    [ "$tries" -gt 1 ] && { echo "SteamCMD-Versuch $tries ..."; sleep 5; }
    "$STEAMCMD" +@sSteamCmdForcePlatformType windows \
        +force_install_dir "$INSTALL_DIR" \
        +login anonymous +app_update "$APPID" validate +quit || true
    [ -f "$ASA_BIN" ] && break
done
[ -f "$ASA_BIN" ] || { echo "FEHLER: ArkAscendedServer.exe nach $tries Versuchen nicht vorhanden." >&2; exit 1; }

echo "[$(date '+%F %T')] Update abgeschlossen."
