#!/usr/bin/env bash
###############################################################################
#  ARK: Survival Ascended Control Panel – Installer (Docker-Variante)
#
#  Installiert in einem Ubuntu-LXC-Container:
#    * Docker + einen ASA-Dedicated-Server als Container
#      (Image: ghcr.io/justamply/asa-linux-server – bringt Proton/Steam-Runtime
#      erprobt mit, umgeht die Proton-Steamworks-Probleme)
#    * Ein login-geschütztes Web-Panel (Start/Stop/Neustart, Update, Config,
#      Karten- und Mod-Verwaltung, RCON)
#
#  Für einen FRISCHEN, unprivilegierten LXC (Ubuntu 24.04) mit  nesting=1.
#  Ausführen IM Container als root:   bash install.sh
###############################################################################
set -euo pipefail

# ------------------------- Einstellungen (anpassbar) ------------------------
ASA_USER="asa"
ASA_HOME="/home/asa"
PANEL_DIR="/opt/asa-panel"
DOCKER_DIR="/opt/asa-panel/docker"
DATA_DIR="/opt/asa-data"
PANEL_PORT="${PANEL_PORT:-80}"
ASA_IMAGE="${ASA_IMAGE:-ghcr.io/justamply/asa-linux-server:latest}"
CONTAINER="asa-server-1"
TZ_VAL="${TZ:-Europe/Berlin}"
# Feste Ports (im Panel gesperrt)
GAME_PORT="${GAME_PORT:-7777}"
QUERY_PORT="${QUERY_PORT:-27015}"
RCON_PORT="${RCON_PORT:-27020}"

PANEL_USER="${PANEL_USER:-}"
PANEL_PASS="${PANEL_PASS:-}"

msg()  { printf '\n\033[1;35m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Bitte als root ausführen (im LXC-Container)."
command -v apt-get >/dev/null || die "Dieser Installer ist für Debian/Ubuntu-LXC gedacht."

MEM_GB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
[ "$MEM_GB" -lt 10 ] && warn "Nur ${MEM_GB} GB RAM erkannt. ASA empfiehlt ~13 GB pro Server."

MMC="$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)"
if [ "$MMC" -lt 262144 ]; then
    warn "vm.max_map_count = ${MMC} (zu niedrig). Auf dem PROXMOX-HOST setzen:"
    warn "  echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-asa.conf && sysctl -p /etc/sysctl.d/99-asa.conf"
fi

if [ -z "$PANEL_USER" ]; then
    read -rp "Panel-Benutzername [admin]: " PANEL_USER; PANEL_USER="${PANEL_USER:-admin}"
fi
if [ -z "$PANEL_PASS" ]; then
    while :; do
        read -rsp "Panel-Passwort: " PANEL_PASS; echo
        [ -n "$PANEL_PASS" ] || { warn "Passwort darf nicht leer sein."; continue; }
        read -rsp "Passwort wiederholen: " P2; echo
        [ "$PANEL_PASS" = "$P2" ] && break || warn "Passwörter stimmen nicht überein."
    done
fi

# ------------------------- Pakete + Docker ----------------------------------
msg "Installiere Basispakete ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
    python3 python3-venv python3-pip sudo curl ca-certificates locales procps
locale-gen en_US.UTF-8 >/dev/null 2>&1 || true

if ! command -v docker >/dev/null 2>&1; then
    msg "Installiere Docker (get.docker.com) ..."
    curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker || true
# Im unprivilegierten LXC hilft fuse-overlayfs, falls der Storage-Driver zickt
if ! docker info >/dev/null 2>&1; then
    warn "Docker startet nicht sauber – installiere fuse-overlayfs und starte neu ..."
    apt-get install -y --no-install-recommends fuse-overlayfs || true
    systemctl restart docker || true
fi
docker info >/dev/null 2>&1 || die "Docker läuft nicht. Prüfe, ob der LXC 'nesting=1' hat (Host: pct set <CTID> --features nesting=1) und starte den Container neu."

# ------------------------- Benutzer -----------------------------------------
msg "Lege Benutzer '$ASA_USER' an ..."
id "$ASA_USER" >/dev/null 2>&1 || useradd -m -d "$ASA_HOME" -s /bin/bash "$ASA_USER"
usermod -aG systemd-journal "$ASA_USER" || true
usermod -aG docker "$ASA_USER" || true

# ------------------------- Datenverzeichnis + Compose -----------------------
msg "Erstelle Datenverzeichnisse und Compose-Setup ..."
mkdir -p "$DATA_DIR/server-files" "$DATA_DIR/steam" "$DATA_DIR/steamcmd"
mkdir -p "$DATA_DIR/server-files/ShooterGame/Saved/Config/WindowsServer"
# 0777: Container-User und Panel-User (asa) teilen sich die Dateien im privaten LXC
chmod -R 0777 "$DATA_DIR"

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -d "$REPO_DIR/src" ] || die "src/ nicht gefunden – install.sh aus dem Repo-Wurzelverzeichnis ausführen."
mkdir -p "$DOCKER_DIR"
cp "$REPO_DIR/docker/docker-compose.yml" "$DOCKER_DIR/docker-compose.yml"

# RCON-/Admin-Passwort erzeugen
RCON_PW="$(python3 -c 'import secrets;print(secrets.token_urlsafe(12))')"

# Grund-Config (Rates etc. + SessionName) vorab anlegen – asa-eigen, 0666
GUS="$DATA_DIR/server-files/ShooterGame/Saved/Config/WindowsServer/GameUserSettings.ini"
if [ ! -f "$GUS" ]; then
    cat > "$GUS" <<EOF
[ServerSettings]
allowThirdPersonPlayer=True

[SessionSettings]
SessionName=ASA Server

[/Script/Engine.GameSession]
MaxPlayers=70
EOF
    chmod 0666 "$GUS"
fi

# ------------------------- Panel-Dateien ------------------------------------
msg "Kopiere Panel-Dateien nach $PANEL_DIR ..."
cp -r "$REPO_DIR/src/app.py" "$REPO_DIR/src/rcon.py" "$REPO_DIR/src/i18n.py" \
      "$REPO_DIR/src/templates" "$REPO_DIR/src/static" "$PANEL_DIR/"
install -m 0755 "$REPO_DIR/src/asa-launch.sh" "$ASA_HOME/asa-launch.sh"
install -m 0755 "$REPO_DIR/src/asa-update.sh" "$ASA_HOME/asa-update.sh"
chown "$ASA_USER":"$ASA_USER" "$ASA_HOME/asa-launch.sh" "$ASA_HOME/asa-update.sh"

# ------------------------- systemd-Units ------------------------------------
msg "Erstelle systemd-Services ..."
# asa.service läuft als ROOT (Docker) und ruft den Startwrapper (docker compose up).
cat > /etc/systemd/system/asa.service <<UNIT
[Unit]
Description=ARK: Survival Ascended Dedicated Server (Docker)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$DOCKER_DIR
Environment=PANEL_DIR=$PANEL_DIR
Environment=DOCKER_DIR=$DOCKER_DIR
ExecStart=$ASA_HOME/asa-launch.sh
ExecStop=/usr/bin/docker compose --env-file $DOCKER_DIR/asa.env stop
TimeoutStopSec=150
Restart=on-failure
RestartSec=20

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/asa-update.service <<UNIT
[Unit]
Description=ASA Docker-Image Update
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
WorkingDirectory=$DOCKER_DIR
Environment=PANEL_DIR=$PANEL_DIR
Environment=DOCKER_DIR=$DOCKER_DIR
ExecStartPre=+/usr/bin/systemctl stop asa.service
ExecStart=$ASA_HOME/asa-update.sh
TimeoutStartSec=3600
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

# ------------------------- Python-venv --------------------------------------
msg "Richte Python-Umgebung ein ..."
python3 -m venv "$PANEL_DIR/venv"
"$PANEL_DIR/venv/bin/pip" install --upgrade pip >/dev/null
"$PANEL_DIR/venv/bin/pip" install flask waitress >/dev/null

# ------------------------- panel.json + Stores ------------------------------
msg "Erzeuge Panel-Konfiguration und ersten Benutzer ..."
PANEL_USER="$PANEL_USER" PANEL_PASS="$PANEL_PASS" PANEL_DIR="$PANEL_DIR" DATA_DIR="$DATA_DIR" \
RCON_PW="$RCON_PW" ASA_IMAGE="$ASA_IMAGE" TZ_VAL="$TZ_VAL" \
GAME_PORT="$GAME_PORT" QUERY_PORT="$QUERY_PORT" RCON_PORT="$RCON_PORT" \
"$PANEL_DIR/venv/bin/python" - <<'PY'
import json, os, secrets
from werkzeug.security import generate_password_hash
pd = os.environ["PANEL_DIR"]; data = os.environ["DATA_DIR"]
conf = {
    "secret_key": secrets.token_hex(32),
    "asa_dir": f"{data}/server-files",
    "data_dir": data,
    "service": "asa.service",
    "update_service": "asa-update.service",
    "users_path": f"{pd}/users.json",
    "runtime_path": f"{pd}/runtime.json",
    "maps_path": f"{pd}/maps.json",
    "mods_path": f"{pd}/mods.json",
    "rcon_host": "127.0.0.1",
    "appid": "2430930",
    "docker": True,
    "container": "asa-server-1",
    "asa_image": os.environ["ASA_IMAGE"],
    "tz": os.environ["TZ_VAL"],
    "rcon_password": os.environ["RCON_PW"],
    "game_port": int(os.environ["GAME_PORT"]),
    "query_port": int(os.environ["QUERY_PORT"]),
    "rcon_port": int(os.environ["RCON_PORT"]),
}
json.dump(conf, open(f"{pd}/panel.json","w"), indent=2)
runtime = {
    "map": "TheIsland_WP", "session_name": "ASA Server", "max_players": 70,
    "port": int(os.environ["GAME_PORT"]), "query_port": int(os.environ["QUERY_PORT"]),
    "rcon_port": int(os.environ["RCON_PORT"]), "public_address": "", "battleye": True,
    "server_password": "", "mods": [], "extra_args": "",
}
json.dump(runtime, open(f"{pd}/runtime.json","w"), indent=2)
json.dump({"maps": []}, open(f"{pd}/maps.json","w"), indent=2)
json.dump({"labels": {}}, open(f"{pd}/mods.json","w"), indent=2)
json.dump({"users": {os.environ["PANEL_USER"]: {"password_hash": generate_password_hash(os.environ["PANEL_PASS"])}}},
          open(f"{pd}/users.json","w"), indent=2)
PY

chown -R "$ASA_USER":"$ASA_USER" "$PANEL_DIR"
chmod 600 "$PANEL_DIR/panel.json" "$PANEL_DIR/users.json"

# ------------------------- sudoers ------------------------------------------
msg "Setze eingeschränkte sudo-Rechte fürs Panel ..."
SUDO_FILE=/etc/sudoers.d/asa-panel
cat > "$SUDO_FILE" <<'SUDO'
asa ALL=(root) NOPASSWD: /usr/bin/systemctl enable --now asa.service, /usr/bin/systemctl disable --now asa.service, /usr/bin/systemctl enable asa.service, /usr/bin/systemctl disable asa.service, /usr/bin/systemctl restart asa.service, /usr/bin/systemctl reset-failed asa.service, /usr/bin/systemctl start asa-update.service, /usr/bin/journalctl -u asa.service *, /usr/bin/journalctl -u asa-update.service *
SUDO
chmod 440 "$SUDO_FILE"
visudo -cf "$SUDO_FILE" >/dev/null || die "sudoers-Regel ungültig."

# ------------------------- aktivieren ---------------------------------------
msg "Aktiviere Services ..."
systemctl daemon-reload
systemctl disable asa.service >/dev/null 2>&1 || true
systemctl enable --now asa-panel.service

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
cat <<DONE

$(printf '\033[1;35m')============================================================$(printf '\033[0m')
  Fertig! Das ASA Control Panel (Docker) ist eingerichtet.

  Web-Panel:   http://${IP:-<container-ip>}:${PANEL_PORT}
  Login:       Benutzer '${PANEL_USER}' + dein gewähltes Passwort

  Ports (in Firewall/OPNsense freigeben) – im Panel gesperrt:
    ${GAME_PORT}/UDP  Spielport
    ${RCON_PORT}/TCP RCON (nur intern nötig)

  RCON/Admin:  ServerAdminPassword: ${RCON_PW}   (bitte notieren)

  Server-Image: ${ASA_IMAGE}
  Daten/Volumes: ${DATA_DIR}  (server-files/steam/steamcmd)

  Erststart: Im Panel "Starten" klicken. Der Container lädt beim ersten Mal
  SteamCMD + die Server-Dateien (~15-30 GB) und generiert die Welt – das dauert
  einige Minuten. Fortschritt im Panel unter "Server-Log" oder:
     docker logs -f ${CONTAINER}

  Der Spielserver ist noch NICHT gestartet.
$(printf '\033[1;35m')============================================================$(printf '\033[0m')
DONE
