#!/usr/bin/env bash
###############################################################################
#  ARK: Survival Ascended Control Panel – Installer
#
#  Installiert in einem Ubuntu-LXC-Container:
#    * ASA-Dedicated-Server (SteamCMD, AppID 2430930) – als Windows-Anwendung,
#      ausgeführt über GE-Proton – als systemd-Service
#    * Ein login-geschütztes Web-Panel (Start/Stop/Neustart, Update, Config,
#      Karten- und Mod-Verwaltung)
#    * Update-Service + automatische Save-Backups
#
#  Ausführen IM Container als root:   bash install.sh
###############################################################################
set -euo pipefail

# ------------------------- Einstellungen (anpassbar) ------------------------
ASA_USER="asa"
ASA_HOME="/home/asa"
INSTALL_DIR="/home/asa/asaserver"
PANEL_DIR="/opt/asa-panel"
PANEL_PORT="${PANEL_PORT:-80}"         # Port des Web-Panels
# Feste Spiel-Ports (werden im Panel gesperrt, siehe Port-Sperre)
GAME_PORT="${GAME_PORT:-7777}"
QUERY_PORT="${QUERY_PORT:-27015}"
RCON_PORT="${RCON_PORT:-27020}"
APPID="2430930"
STEAMCMD="/usr/games/steamcmd"
COMPAT_DATA="$INSTALL_DIR/compatdata"  # Proton-Prefix
STEAM_ROOT="$ASA_HOME/.steam/steam"    # Steam-Client-Pfad für Proton
PROTON_LINK="$ASA_HOME/proton"         # Symlink auf die installierte GE-Proton-Version
PROTON_VERSION="${PROTON_VERSION:-latest}"   # GE-Proton-Release (Tag) oder 'latest'

# Panel-Zugangsdaten: aus Umgebungsvariablen oder interaktiv abfragen
PANEL_USER="${PANEL_USER:-}"
PANEL_PASS="${PANEL_PASS:-}"

msg()  { printf '\n\033[1;35m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Bitte als root ausführen (im LXC-Container)."
command -v apt-get >/dev/null || die "Dieser Installer ist für Debian/Ubuntu-LXC gedacht."

# RAM-Hinweis – ASA ist deutlich hungriger als ARK: SE (12–16 GB empfohlen)
MEM_GB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
if [ "$MEM_GB" -lt 10 ]; then
    warn "Nur ${MEM_GB} GB RAM erkannt. ASA empfiehlt 12–16 GB (min. 10 GB)."
fi

# vm.max_map_count-Hinweis: ASA (UE5) mappt sehr viele Speicherregionen. Ist der
# Wert zu niedrig, stürzt der Server trotz freiem RAM ab. Der Parameter ist
# HOSTWEIT und im (unprivilegierten) LXC nicht setzbar – daher nur warnen.
MMC="$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)"
if [ "$MMC" -lt 262144 ]; then
    warn "vm.max_map_count = ${MMC} (zu niedrig – ASA braucht mind. 262144)."
    warn "Auf dem PROXMOX-HOST setzen (nicht im Container):"
    warn "  echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-asa.conf && sysctl -p /etc/sysctl.d/99-asa.conf"
fi

# Zugangsdaten abfragen, falls nicht gesetzt
if [ -z "$PANEL_USER" ]; then
    read -rp "Panel-Benutzername [admin]: " PANEL_USER
    PANEL_USER="${PANEL_USER:-admin}"
fi
if [ -z "$PANEL_PASS" ]; then
    while :; do
        read -rsp "Panel-Passwort: " PANEL_PASS; echo
        [ -n "$PANEL_PASS" ] || { warn "Passwort darf nicht leer sein."; continue; }
        read -rsp "Passwort wiederholen: " P2; echo
        [ "$PANEL_PASS" = "$P2" ] && break || warn "Passwörter stimmen nicht überein."
    done
fi

# ------------------------- Pakete installieren ------------------------------
msg "Aktualisiere Paketquellen und installiere Abhängigkeiten ..."
export DEBIAN_FRONTEND=noninteractive
dpkg --add-architecture i386
apt-get update -y
apt-get install -y --no-install-recommends software-properties-common ca-certificates
add-apt-repository -y multiverse
add-apt-repository -y universe
apt-get update -y

# SteamCMD-Lizenz vorab akzeptieren (sonst interaktiver Dialog)
echo steam steam/question select "I AGREE" | debconf-set-selections
echo steam steam/license note '' | debconf-set-selections

# steamcmd + 32-bit-Libs; Proton bringt sein eigenes Wine mit, braucht aber ein
# paar System-Libs. Wichtig für ASA (UE5/DX12 -> VKD3D -> Vulkan) im GPU-losen
# Container:
#   * libvulkan1        = Vulkan-Loader (sonst crasht Proton beim Start an libvulkan.so.1)
#   * mesa-vulkan-drivers = Software-Vulkan (lavapipe/llvmpipe) als Vulkan-GERÄT;
#     ohne ein Device hängt der Server beim Rendering-Init, bevor er startet.
# curl/tar für GE-Proton.
apt-get install -y --no-install-recommends \
    steamcmd lib32gcc-s1 lib32stdc++6 \
    python3 python3-venv python3-pip \
    sudo curl tar xz-utils locales procps \
    libfreetype6 libfreetype6:i386 \
    libvulkan1 mesa-vulkan-drivers || {
        apt-get install -y --no-install-recommends libvulkan1
        apt-get install -y --no-install-recommends mesa-vulkan-drivers
    }
# 32-bit-Varianten best effort (Server ist 64-bit, aber schadet nicht)
apt-get install -y --no-install-recommends libvulkan1:i386 mesa-vulkan-drivers:i386 2>/dev/null || true

locale-gen en_US.UTF-8 >/dev/null 2>&1 || true

# ------------------------- Benutzer anlegen ---------------------------------
msg "Lege Benutzer '$ASA_USER' an ..."
if ! id "$ASA_USER" >/dev/null 2>&1; then
    useradd -m -d "$ASA_HOME" -s /bin/bash "$ASA_USER"
fi
usermod -aG systemd-journal "$ASA_USER" || true

# ------------------------- ASA-Server installieren --------------------------
# Wichtig: ASA ist eine WINDOWS-Anwendung -> SteamCMD muss die Windows-Depots
# laden (+@sSteamCmdForcePlatformType windows), sonst kommt die .exe nicht.
# Beim allerersten Lauf ist der Depot-Cache leer ("Missing configuration"),
# daher auf die Binary prüfen und bis zu 5x wiederholen.
msg "Installiere ASA-Server via SteamCMD (mehrere GB, kann lange dauern) ..."
ASA_BIN="$INSTALL_DIR/ShooterGame/Binaries/Win64/ArkAscendedServer.exe"
tries=0
while [ ! -f "$ASA_BIN" ] && [ "$tries" -lt 5 ]; do
    tries=$((tries+1))
    [ "$tries" -gt 1 ] && { warn "SteamCMD-Versuch $tries ('Missing configuration' beim 1. Lauf ist normal) ..."; sleep 5; }
    sudo -u "$ASA_USER" -H bash -c "\
        '$STEAMCMD' +@sSteamCmdForcePlatformType windows \
        +force_install_dir '$INSTALL_DIR' \
        +login anonymous +app_update '$APPID' validate +quit" || true
done
[ -f "$ASA_BIN" ] || die "ArkAscendedServer.exe nach $tries Versuchen nicht vorhanden – Steam-Logs prüfen: ~${ASA_USER}/.steam/logs/"

# ------------------------- GE-Proton installieren ---------------------------
msg "Installiere GE-Proton (Laufzeit für die Windows-.exe) ..."
sudo -u "$ASA_USER" -H PROTON_VERSION="$PROTON_VERSION" bash <<'PROT'
set -euo pipefail
CT_DIR="$HOME/.steam/compatibilitytools.d"
mkdir -p "$CT_DIR" "$HOME/.steam/steam" "$HOME/.steam/sdk64"
# aktuelle (oder gewünschte) GE-Proton-Release-URL bestimmen
if [ "${PROTON_VERSION:-latest}" = "latest" ]; then
    API="https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest"
else
    API="https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/tags/${PROTON_VERSION}"
fi
URL="$(python3 - "$API" <<'PY'
import json, sys, urllib.request
req = urllib.request.Request(sys.argv[1], headers={"User-Agent": "asa-panel-installer"})
data = json.load(urllib.request.urlopen(req, timeout=30))
tag = data["tag_name"]
url = ""
for a in data.get("assets", []):
    n = a["name"]
    if n.endswith(".tar.gz") and n.startswith("GE-Proton"):
        url = a["browser_download_url"]
print(tag)
print(url)
PY
)"
TAG="$(printf '%s\n' "$URL" | sed -n 1p)"
DL="$(printf '%s\n' "$URL" | sed -n 2p)"
[ -n "$DL" ] || { echo "Konnte GE-Proton-Download-URL nicht ermitteln." >&2; exit 1; }
echo "GE-Proton: $TAG"
if [ ! -d "$CT_DIR/$TAG" ]; then
    curl -fL "$DL" -o "$HOME/geproton.tar.gz"
    tar -xzf "$HOME/geproton.tar.gz" -C "$CT_DIR"
    rm -f "$HOME/geproton.tar.gz"
fi
# Symlink ~/proton -> installierte Version
PDIR="$(find "$CT_DIR" -maxdepth 1 -type d -name 'GE-Proton*' | sort -V | tail -n1)"
ln -sfn "$PDIR" "$HOME/proton"
# steamclient.so für das SDK verlinken (Proton/EOS erwartet es dort)
SC="$(find "$HOME/.steam" "$HOME/Steam" -name steamclient.so 2>/dev/null | head -n1 || true)"
[ -n "$SC" ] && ln -sf "$SC" "$HOME/.steam/sdk64/steamclient.so" || true
echo "Proton verlinkt: $HOME/proton -> $PDIR"
PROT
[ -x "$PROTON_LINK/proton" ] || die "GE-Proton-Installation fehlgeschlagen ($PROTON_LINK/proton fehlt)."

# ------------------------- Proton-Prefix initialisieren ---------------------
msg "Initialisiere Proton-Prefix ..."
sudo -u "$ASA_USER" -H bash -c "\
    mkdir -p '$COMPAT_DATA'; \
    STEAM_COMPAT_DATA_PATH='$COMPAT_DATA' \
    STEAM_COMPAT_CLIENT_INSTALL_PATH='$STEAM_ROOT' \
    '$PROTON_LINK/proton' run wineboot --init >/dev/null 2>&1 || true"

# ------------------------- Grund-Config + RCON ------------------------------
msg "Bereite GameUserSettings.ini vor (RCON aktiviert, Admin-Passwort erzeugt) ..."
RCON_PW="$(python3 -c 'import secrets;print(secrets.token_urlsafe(12))')"
CFGDIR="$INSTALL_DIR/ShooterGame/Saved/Config/WindowsServer"
sudo -u "$ASA_USER" -H bash -c "mkdir -p '$CFGDIR'"
GUS="$CFGDIR/GameUserSettings.ini"
if [ ! -f "$GUS" ]; then
    cat > "$GUS" <<EOF
[ServerSettings]
ServerAdminPassword=$RCON_PW
RCONEnabled=True
RCONPort=$RCON_PORT
ServerPassword=
allowThirdPersonPlayer=True

[SessionSettings]
SessionName=ASA Server

[/Script/Engine.GameSession]
MaxPlayers=70
EOF
fi
chown -R "$ASA_USER":"$ASA_USER" "$INSTALL_DIR/ShooterGame/Saved" 2>/dev/null || true

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -d "$REPO_DIR/src" ] || die "src/ nicht gefunden – bitte install.sh aus dem Repo-Wurzelverzeichnis ausführen."

msg "Kopiere Panel-Dateien nach $PANEL_DIR ..."
mkdir -p "$PANEL_DIR"
cp -r "$REPO_DIR/src/app.py" "$REPO_DIR/src/rcon.py" "$REPO_DIR/src/i18n.py" \
      "$REPO_DIR/src/templates" "$REPO_DIR/src/static" "$PANEL_DIR/"
install -m 0755 "$REPO_DIR/src/asa-launch.sh"  "$ASA_HOME/asa-launch.sh"
install -m 0755 "$REPO_DIR/src/asa-update.sh"  "$ASA_HOME/asa-update.sh"
chown "$ASA_USER":"$ASA_USER" "$ASA_HOME/asa-launch.sh" "$ASA_HOME/asa-update.sh"

# ------------------------- systemd-Units ------------------------------------
msg "Erstelle systemd-Services ..."

cat > /etc/systemd/system/asa.service <<UNIT
[Unit]
Description=ARK: Survival Ascended Dedicated Server (Proton)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$ASA_USER
Group=$ASA_USER
WorkingDirectory=$INSTALL_DIR/ShooterGame/Binaries/Win64
Environment=INSTALL_DIR=$INSTALL_DIR
Environment=RUNTIME=$PANEL_DIR/runtime.json
Environment=PROTON_DIR=$PROTON_LINK
Environment=COMPAT_DATA=$COMPAT_DATA
Environment=STEAM_ROOT=$STEAM_ROOT
ExecStart=$ASA_HOME/asa-launch.sh
# ASA/Proton öffnen sehr viele Dateien -> Limit hochsetzen
LimitNOFILE=100000
Restart=on-failure
RestartSec=20

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/asa-update.service <<UNIT
[Unit]
Description=ASA Server Update (SteamCMD, Windows-Depots)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$ASA_USER
Group=$ASA_USER
WorkingDirectory=$INSTALL_DIR
Environment=INSTALL_DIR=$INSTALL_DIR
# Server vor dem Update stoppen (mit Root-Rechten, daher '+')
ExecStartPre=+/usr/bin/systemctl stop asa.service
ExecStart=$ASA_HOME/asa-update.sh
TimeoutStartSec=7200
UNIT

cat > /etc/systemd/system/asa-panel.service <<UNIT
[Unit]
Description=ASA Control Panel (Web UI)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$ASA_USER
Group=$ASA_USER
AmbientCapabilities=CAP_NET_BIND_SERVICE
WorkingDirectory=$PANEL_DIR
Environment=PANEL_CONFIG=$PANEL_DIR/panel.json
ExecStart=$PANEL_DIR/venv/bin/waitress-serve --listen=0.0.0.0:__PANEL_PORT__ app:app
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
sed -i "s/__PANEL_PORT__/${PANEL_PORT}/" /etc/systemd/system/asa-panel.service

# ------------------------- Python-venv + Flask ------------------------------
msg "Richte Python-Umgebung für das Panel ein ..."
python3 -m venv "$PANEL_DIR/venv"
"$PANEL_DIR/venv/bin/pip" install --upgrade pip >/dev/null
"$PANEL_DIR/venv/bin/pip" install flask waitress >/dev/null

# ------------------------- panel.json + Stores ------------------------------
msg "Erzeuge Panel-Konfiguration, Laufzeitdaten und ersten Benutzer ..."
PANEL_USER="$PANEL_USER" PANEL_PASS="$PANEL_PASS" INSTALL_DIR="$INSTALL_DIR" PANEL_DIR="$PANEL_DIR" \
GAME_PORT="$GAME_PORT" QUERY_PORT="$QUERY_PORT" RCON_PORT="$RCON_PORT" \
"$PANEL_DIR/venv/bin/python" - <<'PY'
import json, os, secrets
from werkzeug.security import generate_password_hash

panel_dir = os.environ["PANEL_DIR"]
game_port = int(os.environ["GAME_PORT"])
query_port = int(os.environ["QUERY_PORT"])
rcon_port = int(os.environ["RCON_PORT"])
conf = {
    "secret_key": secrets.token_hex(32),
    "asa_dir": os.environ["INSTALL_DIR"],
    "service": "asa.service",
    "update_service": "asa-update.service",
    "users_path": f"{panel_dir}/users.json",
    "runtime_path": f"{panel_dir}/runtime.json",
    "maps_path": f"{panel_dir}/maps.json",
    "mods_path": f"{panel_dir}/mods.json",
    "rcon_host": "127.0.0.1",
    "appid": "2430930",
    # feste Ports -> im Panel gesperrt (Port-Sperre)
    "game_port": game_port,
    "query_port": query_port,
    "rcon_port": rcon_port,
}
with open(f"{panel_dir}/panel.json", "w") as fh:
    json.dump(conf, fh, indent=2)

runtime = {
    "map": "TheIsland_WP",
    "session_name": "ASA Server",
    "max_players": 70,
    "port": game_port,
    "query_port": query_port,
    "rcon_port": rcon_port,
    "public_address": "",
    "battleye": True,
    "server_password": "",
    "mods": [],
    "extra_args": "",
}
with open(f"{panel_dir}/runtime.json", "w") as fh:
    json.dump(runtime, fh, indent=2)

for path, empty in ((f"{panel_dir}/maps.json", {"maps": []}),
                    (f"{panel_dir}/mods.json", {"labels": {}})):
    with open(path, "w") as fh:
        json.dump(empty, fh, indent=2)

users = {"users": {
    os.environ["PANEL_USER"]: {"password_hash": generate_password_hash(os.environ["PANEL_PASS"])}
}}
with open(f"{panel_dir}/users.json", "w") as fh:
    json.dump(users, fh, indent=2)
PY

# ------------------------- Rechte ------------------------------------------
chown -R "$ASA_USER":"$ASA_USER" "$PANEL_DIR"
chmod 600 "$PANEL_DIR/panel.json" "$PANEL_DIR/users.json"
chmod 640 "$PANEL_DIR/runtime.json" "$PANEL_DIR/maps.json" "$PANEL_DIR/mods.json"

# ------------------------- sudoers-Regel ------------------------------------
msg "Setze eingeschränkte sudo-Rechte für das Panel ..."
SUDO_FILE=/etc/sudoers.d/asa-panel
cat > "$SUDO_FILE" <<'SUDO'
asa ALL=(root) NOPASSWD: /usr/bin/systemctl enable --now asa.service, /usr/bin/systemctl disable --now asa.service, /usr/bin/systemctl enable asa.service, /usr/bin/systemctl disable asa.service, /usr/bin/systemctl restart asa.service, /usr/bin/systemctl reset-failed asa.service, /usr/bin/systemctl start asa-update.service, /usr/bin/journalctl -u asa.service *, /usr/bin/journalctl -u asa-update.service *
SUDO
chmod 440 "$SUDO_FILE"
visudo -cf "$SUDO_FILE" >/dev/null || die "sudoers-Regel ungültig."

# ------------------------- Services aktivieren ------------------------------
msg "Aktiviere Services ..."
systemctl daemon-reload
# asa.service startet nach einem Reboot nur, wenn er zuletzt lief (Start=an, Stopp=aus).
systemctl disable asa.service >/dev/null 2>&1 || true
systemctl enable --now asa-panel.service

# ------------------------- Zusammenfassung ----------------------------------
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
cat <<DONE

$(printf '\033[1;35m')============================================================$(printf '\033[0m')
  Fertig! Das ASA Control Panel ist eingerichtet.

  Web-Panel:   http://${IP:-<container-ip>}:${PANEL_PORT}
  Login:       Benutzer '${PANEL_USER}' + dein gewähltes Passwort

  Ports (in Firewall/OPNsense freigeben) – beim Installieren festgelegt & im Panel gesperrt:
    ${GAME_PORT}/UDP  Spielport (ASA nutzt nur den Spielport, kein Steam-Query nötig)
    ${RCON_PORT}/TCP RCON (nur intern nötig, kann zu bleiben)
    (Andere Ports mit  GAME_PORT=... RCON_PORT=... bash install.sh  wählbar.)

  RCON/Admin:  ServerAdminPassword (= RCON- und In-Game-Admin-Passwort): ${RCON_PW}
               -> bitte notieren.

  Karten:      im Panel unter "Karten" auswählen (Standard: The Island).
  Mods:        im Panel unter "Mods" die CurseForge-Mod-IDs eintragen –
               der Server lädt sie beim nächsten Start selbst.

  Autostart:   Der Server startet nach einem Reboot nur, wenn er zuletzt lief.
               Start im Panel = Autostart an, Stopp = Autostart aus.
               Der LXC selbst startet über Proxmox (Container-Option onboot=1).

  Der Spielserver ist noch NICHT gestartet – erst im Panel Karte/Mods prüfen,
  dann "Starten" klicken. Der erste Start dauert (Proton-Prefix + Weltgenerierung).

  Updates:     Im Panel unter "Ressourcen" zeigt "Nach Updates suchen", ob eine
               neuere Server-Build-ID verfügbar ist. Optionaler täglicher
               Panel-Selbst-Update-Timer:
                 sudo bash scripts/setup-autoupdate.sh

  Nützliche Befehle:
    systemctl status asa.service
    journalctl -u asa.service -f
    systemctl status asa-panel.service
$(printf '\033[1;35m')============================================================$(printf '\033[0m')
DONE
