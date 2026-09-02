#!/usr/bin/env bash
###############################################################################
# ASA-Startwrapper (Docker-Variante)
#
# Baut aus runtime.json den ASA_START_PARAMS-String (Karte, Ports, RCON, Mods,
# MaxPlayers, BattlEye, Extra-Args), schreibt asa.env und startet den Container
# über docker compose IM VORDERGRUND – so steuert systemd (asa.service) den
# Lebenszyklus (Start/Stop/Neustart/Autostart) wie bisher.
#
# Wird als root von asa.service ausgeführt (Docker braucht Root/Docker-Gruppe).
###############################################################################
set -euo pipefail

PANEL_DIR="${PANEL_DIR:-/opt/asa-panel}"
DOCKER_DIR="${DOCKER_DIR:-$PANEL_DIR/docker}"
RUNTIME="${RUNTIME:-$PANEL_DIR/runtime.json}"
PANEL_CONF="${PANEL_CONF:-$PANEL_DIR/panel.json}"
ENV_FILE="$DOCKER_DIR/asa.env"

# Werte aus panel.json (feste Ports, RCON-Passwort, Datenverzeichnis, Image, TZ)
eval "$(python3 - "$PANEL_CONF" <<'PY'
import json, sys, shlex
c = json.load(open(sys.argv[1]))
def q(v): return shlex.quote(str(v))
print("DATA_DIR=" + q(c.get("data_dir", "/opt/asa-data")))
print("RCON_PW=" + q(c.get("rcon_password", "")))
print("GAME_PORT=" + q(c.get("game_port", 7777)))
print("QUERY_PORT=" + q(c.get("query_port", 27015)))
print("RCON_PORT=" + q(c.get("rcon_port", 27020)))
print("ASA_IMAGE=" + q(c.get("asa_image", "ghcr.io/justamply/asa-linux-server:latest")))
print("TZ_VAL=" + q(c.get("tz", "Europe/Berlin")))
PY
)"

# Werte aus runtime.json (Karte, Session, Mods, Startoptionen)
eval "$(python3 - "$RUNTIME" <<'PY'
import json, sys, shlex
d = json.load(open(sys.argv[1])) if __import__("os").path.exists(sys.argv[1]) else {}
def q(v): return shlex.quote(str(v))
print("MAP=" + q(d.get("map", "TheIsland_WP")))
print("SESSION=" + q(d.get("session_name", "ASA Server")))
print("MAXP=" + q(d.get("max_players", 70)))
print("BATTLEYE=" + q("1" if d.get("battleye", True) else ""))
print("SRVPW=" + q(d.get("server_password", "")))
print("MODS=" + q(",".join(str(m) for m in d.get("mods", []) if str(m).isdigit())))
print("EXTRA=" + q(d.get("extra_args", "")))
PY
)"

# SessionName (kann Leerzeichen enthalten) NICHT in ASA_START_PARAMS packen –
# der Container zerlegt den String an Leerzeichen. Stattdessen in die INI setzen.
GUS="$DATA_DIR/server-files/ShooterGame/Saved/Config/WindowsServer/GameUserSettings.ini"
python3 - "$GUS" "$SESSION" <<'PY' || true
import sys, os
gus, name = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(gus), exist_ok=True)
lines = []
if os.path.exists(gus):
    raw = open(gus, "rb").read()
    enc = "utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else ("utf-8-sig" if raw[:3]==b"\xef\xbb\xbf" else "utf-8")
    lines = raw.decode(enc, "ignore").replace("\r","").split("\n")
out, in_sess, done, seen = [], False, False, False
for ln in lines:
    s = ln.strip()
    if s.startswith("[") and s.endswith("]"):
        if in_sess and not done:
            out.append("SessionName=%s" % name); done = True
        in_sess = (s == "[SessionSettings]"); seen = seen or in_sess
        out.append(ln); continue
    if in_sess and s.lower().startswith("sessionname="):
        out.append("SessionName=%s" % name); done = True; continue
    out.append(ln)
if not done:
    if in_sess:
        out.append("SessionName=%s" % name)
    elif not seen:
        if out and out[-1].strip() != "": out.append("")
        out += ["[SessionSettings]", "SessionName=%s" % name]
text = "\n".join(out)
if not text.endswith("\n"): text += "\n"
tmp = gus + ".tmp"
open(tmp, "w", encoding="utf-8").write(text)
try: os.chmod(tmp, 0o666)
except OSError: pass
os.replace(tmp, gus)
PY

# ASA_START_PARAMS zusammenbauen (nur Tokens ohne Leerzeichen INNERHALB eines Wertes)
OPTS="${MAP}?listen?Port=${GAME_PORT}?QueryPort=${QUERY_PORT}?RCONPort=${RCON_PORT}?RCONEnabled=True"
[ -n "$RCON_PW" ] && OPTS="${OPTS}?ServerAdminPassword=${RCON_PW}"
[ -n "$SRVPW" ] && OPTS="${OPTS}?ServerPassword=${SRVPW}"
PARAMS="${OPTS} -WinLiveMaxPlayers=${MAXP}"
[ -n "$MODS" ] && PARAMS="${PARAMS} -mods=${MODS}"
[ -z "$BATTLEYE" ] && PARAMS="${PARAMS} -NoBattlEye"
[ -n "$EXTRA" ] && PARAMS="${PARAMS} ${EXTRA}"

# asa.env schreiben (docker compose liest sie via --env-file)
mkdir -p "$DOCKER_DIR"
{
  echo "DATA_DIR=${DATA_DIR}"
  echo "ASA_IMAGE=${ASA_IMAGE}"
  echo "GAME_PORT=${GAME_PORT}"
  echo "RCON_PORT=${RCON_PORT}"
  echo "TZ=${TZ_VAL}"
  echo "ASA_START_PARAMS=${PARAMS}"
} > "$ENV_FILE"

echo "[asa-launch] Karte=$MAP  Mods=${MODS:-–}  Port=$GAME_PORT/udp  RCON=$RCON_PORT  MaxPlayers=$MAXP"
echo "[asa-launch] Container=asa-server-1  Image=$ASA_IMAGE"

cd "$DOCKER_DIR"
# Vordergrund: systemd verfolgt den Prozess; SIGTERM -> compose stoppt den Container
exec docker compose --env-file "$ENV_FILE" up --no-log-prefix
