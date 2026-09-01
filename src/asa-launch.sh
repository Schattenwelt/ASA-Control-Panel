#!/usr/bin/env bash
###############################################################################
# ASA-Startwrapper (ARK: Survival Ascended)
#
# ASA hat KEIN natives Linux-Binary – der Server ist eine Windows-Anwendung
# (ArkAscendedServer.exe) und wird hier über Proton (GE-Proton) gestartet.
# Diese Datei baut die Startzeile aus runtime.json (Karte, Mods, Ports,
# Startargumente) + ServerAdminPassword aus GameUserSettings.ini zusammen und
# ruft sie via Proton auf. Wird per systemd (asa.service, ExecStart) gestartet.
#
# Mods: ASA lädt Mods eigenständig von CurseForge, wenn sie per -mods=<IDs> auf
# der Kommandozeile stehen. Es gibt KEIN ActiveMods= und keinen manuellen
# Entpack-Schritt wie bei ARK: Survival Evolved.
###############################################################################
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/home/asa/asaserver}"
RUNTIME="${RUNTIME:-/opt/asa-panel/runtime.json}"
GUS="$INSTALL_DIR/ShooterGame/Saved/Config/WindowsServer/GameUserSettings.ini"
BIN="$INSTALL_DIR/ShooterGame/Binaries/Win64/ArkAscendedServer.exe"

# Proton-Umgebung (vom Installer eingerichtet)
PROTON_DIR="${PROTON_DIR:-$HOME/proton}"                 # Symlink auf die aktuelle GE-Proton-Version
COMPAT_DATA="${COMPAT_DATA:-$INSTALL_DIR/compatdata}"    # Proton-Prefix (WINEPREFIX-Träger)
STEAM_ROOT="${STEAM_ROOT:-$HOME/.steam/steam}"           # Steam-Client-Install-Pfad (für Proton)

[ -f "$BIN" ]            || { echo "ArkAscendedServer.exe nicht gefunden: $BIN" >&2; exit 1; }
[ -x "$PROTON_DIR/proton" ] || { echo "Proton nicht gefunden: $PROTON_DIR/proton" >&2; exit 1; }

# --- runtime.json einlesen (als Shell-Variablen) ----------------------------
if [ -f "$RUNTIME" ]; then
    eval "$(python3 - "$RUNTIME" <<'PY'
import json, sys, shlex
d = json.load(open(sys.argv[1]))
def q(v): return shlex.quote(str(v))
print("MAP=" + q(d.get("map", "TheIsland_WP")))
print("SESSION=" + q(d.get("session_name", "ASA Server")))
print("MAXP=" + q(d.get("max_players", 70)))
print("PORT=" + q(d.get("port", 7777)))
print("QUERY=" + q(d.get("query_port", 27015)))
print("RCONP=" + q(d.get("rcon_port", 27020)))
print("BATTLEYE=" + q("1" if d.get("battleye", True) else ""))
print("SRVPW=" + q(d.get("server_password", "")))
print("MODS=" + q(",".join(str(m) for m in d.get("mods", []) if str(m).isdigit())))
print("EXTRA=" + q(d.get("extra_args", "")))
PY
)"
else
    MAP="TheIsland_WP"; SESSION="ASA Server"; MAXP=70; PORT=7777; QUERY=27015
    RCONP=27020; BATTLEYE="1"; SRVPW=""; MODS=""; EXTRA=""
fi

# --- ServerAdminPassword aus der INI ziehen (für RCON) ----------------------
# encoding-bewusst: ARK schreibt die INI beim Beenden ggf. als UTF-16, dann würde
# ein ASCII-grep das Passwort nicht mehr finden (Null-Bytes zwischen den Zeichen).
ADMINPW=""
if [ -f "$GUS" ]; then
    ADMINPW="$(python3 - "$GUS" <<'PY' || true
import sys
raw = open(sys.argv[1], "rb").read()
if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
    enc = "utf-16"
elif raw[:3] == b"\xef\xbb\xbf":
    enc = "utf-8-sig"
else:
    enc = "utf-8"
for line in raw.decode(enc, "ignore").splitlines():
    s = line.strip()
    if s.lower().startswith("serveradminpassword="):
        print(s.split("=", 1)[1].strip()); break
PY
)"
fi

# --- ?-Optionsteil zusammenbauen --------------------------------------------
# ASA übernimmt Session/Ports/RCON über den ?-Optionsteil hinter der Karte.
OPTS="${MAP}?listen?SessionName=${SESSION}?Port=${PORT}?QueryPort=${QUERY}?RCONEnabled=True?RCONPort=${RCONP}"
[ -n "$ADMINPW" ] && OPTS="${OPTS}?ServerAdminPassword=${ADMINPW}"
[ -n "$SRVPW" ] && OPTS="${OPTS}?ServerPassword=${SRVPW}"

# --- Startargumente ----------------------------------------------------------
# ASA-Besonderheiten:
#   * MaxPlayers wird über -WinLiveMaxPlayers=N gesetzt (NICHT ?MaxPlayers=).
#   * Mods kommen als -mods=ID1,ID2 (CurseForge, Server lädt sie selbst).
ARGS=(-log "-WinLiveMaxPlayers=${MAXP}")
[ -n "$MODS" ] && ARGS+=("-mods=${MODS}")
[ -z "$BATTLEYE" ] && ARGS+=(-NoBattlEye)
if [ -n "$EXTRA" ]; then
    read -r -a EXTRA_ARR <<< "$EXTRA"
    ARGS+=("${EXTRA_ARR[@]}")
fi

# --- Proton-Umgebung ---------------------------------------------------------
export STEAM_COMPAT_DATA_PATH="$COMPAT_DATA"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT"
mkdir -p "$COMPAT_DATA"
cd "$(dirname "$BIN")"

# Erststart: Proton-Prefix anlegen, BEVOR die Server-.exe gestartet wird.
# Sonst baut der erste 'proton run <exe>' nur den Prefix auf und die .exe läuft
# noch nicht (bekanntes Proton-Verhalten – man müsste sonst zweimal starten).
if [ ! -f "$COMPAT_DATA/pfx/system.reg" ]; then
    echo "[asa-launch] Erststart erkannt – initialisiere Proton-Prefix (einmalig, dauert kurz) ..."
    "$PROTON_DIR/proton" run wineboot --init >/dev/null 2>&1 || true
    # warten, bis der Prefix wirklich steht
    for _ in $(seq 1 30); do
        [ -f "$COMPAT_DATA/pfx/system.reg" ] && break
        sleep 1
    done
    echo "[asa-launch] Prefix initialisiert."
fi

echo "[asa-launch] Karte=$MAP  Mods=${MODS:-–}  Port=$PORT/$QUERY  RCON=$RCONP  MaxPlayers=$MAXP"
echo "[asa-launch] Proton=$PROTON_DIR  Prefix=$COMPAT_DATA"
exec "$PROTON_DIR/proton" run "$BIN" "$OPTS" "${ARGS[@]}"
