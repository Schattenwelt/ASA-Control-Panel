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

# ServerAdminPassword bereinigen + ServerPassword als eigene INI-Zeile schreiben.
# Grund: steht ?ServerPassword= direkt hinter ?ServerAdminPassword= in der
# Kommandozeile, klebt der Container beim Zurückschreiben beides in EIN INI-Feld
# ("pw?ServerPassword=xyz"). Deshalb: ServerPassword NICHT in die Startparameter,
# sondern in [ServerSettings]; und ein evtl. schon verkorkstes Admin-Passwort
# (alles ab dem ersten '?') hier heilen.
python3 - "$GUS" "$SRVPW" <<'PY' || true
import sys, os
gus, srvpw = sys.argv[1], sys.argv[2]
lines = []
if os.path.exists(gus):
    raw = open(gus, "rb").read()
    enc = "utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else ("utf-8-sig" if raw[:3]==b"\xef\xbb\xbf" else "utf-8")
    lines = raw.decode(enc, "ignore").replace("\r","").split("\n")
def clean(v): return v.split("?", 1)[0].strip()
out, in_ss, seen_ss, done_sp = [], False, False, False
for ln in lines:
    s = ln.strip()
    if s.startswith("[") and s.endswith("]"):
        if in_ss and not done_sp:
            out.append("ServerPassword=%s" % srvpw); done_sp = True
        in_ss = (s == "[ServerSettings]"); seen_ss = seen_ss or in_ss
        out.append(ln); continue
    if in_ss and s.lower().startswith("serveradminpassword="):
        out.append("ServerAdminPassword=%s" % clean(s.split("=", 1)[1])); continue
    if in_ss and s.lower().startswith("serverpassword="):
        out.append("ServerPassword=%s" % srvpw); done_sp = True; continue
    out.append(ln)
if in_ss and not done_sp:
    out.append("ServerPassword=%s" % srvpw); done_sp = True
if not seen_ss:
    if out and out[-1].strip() != "": out.append("")
    out += ["[ServerSettings]", "ServerPassword=%s" % srvpw]
text = "\n".join(out)
if not text.endswith("\n"): text += "\n"
tmp = gus + ".tmp"; open(tmp, "w", encoding="utf-8").write(text)
try: os.chmod(tmp, 0o666)
except OSError: pass
os.replace(tmp, gus)
PY

# ServerAdminPassword aus der INI lesen (dort ändert es der Eigentümer im
# Config-Editor). Nur wenn dort keins steht, den Seed-Wert aus panel.json nehmen.
INI_PW="$(python3 - "$GUS" <<'PY' || true
import sys, os
gus = sys.argv[1]
if os.path.exists(gus):
    raw = open(gus, "rb").read()
    enc = "utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else ("utf-8-sig" if raw[:3]==b"\xef\xbb\xbf" else "utf-8")
    for ln in raw.decode(enc, "ignore").splitlines():
        s = ln.strip()
        if s.lower().startswith("serveradminpassword="):
            print(s.split("=", 1)[1].split("?", 1)[0].strip()); break
PY
)"
[ -n "$INI_PW" ] && RCON_PW="$INI_PW"

# ASA_START_PARAMS zusammenbauen (nur Tokens ohne Leerzeichen INNERHALB eines Wertes).
# ServerPassword steht in der INI (siehe oben), NICHT hier – sonst klebt es ans
# Admin-Passwort. ServerAdminPassword als letztes ?-Token vor den -Flags.
OPTS="${MAP}?listen?Port=${GAME_PORT}?QueryPort=${QUERY_PORT}?RCONPort=${RCON_PORT}?RCONEnabled=True"
[ -n "$RCON_PW" ] && OPTS="${OPTS}?ServerAdminPassword=${RCON_PW}"
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
