#!/usr/bin/env bash
# Aktualisiert nur den Panel-Code (app.py, rcon.py, i18n.py, Templates, CSS) aus dem
# ausgecheckten Repo und startet das Panel neu. Nutzerdaten/Runtime bleiben unangetastet.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PANEL_DIR="/opt/asa-panel"; ASA_USER="asa"
[ "$(id -u)" -eq 0 ] || { echo "Bitte als root ausführen." >&2; exit 1; }
[ -d "$PANEL_DIR" ] || { echo "$PANEL_DIR fehlt – zuerst install.sh ausführen." >&2; exit 1; }
cp -r "$REPO_DIR/src/app.py" "$REPO_DIR/src/rcon.py" "$REPO_DIR/src/i18n.py" \
      "$REPO_DIR/src/templates" "$REPO_DIR/src/static" "$PANEL_DIR/"
install -m 0755 "$REPO_DIR/src/asa-launch.sh" /home/asa/asa-launch.sh
install -m 0755 "$REPO_DIR/src/asa-update.sh" /home/asa/asa-update.sh

# Bestehende panel.json um neue Schlüssel ergänzen (appid + feste Ports), ohne
# vorhandene Werte zu überschreiben. So wird die Port-/RCON-Sperre auch bei einer
# vor diesem Update angelegten Installation aktiv. Ports werden – falls nicht schon
# gesetzt – aus der runtime.json übernommen (sonst Standardwerte).
python3 - "$PANEL_DIR/panel.json" "$PANEL_DIR/runtime.json" <<'PY' || true
import json, os, sys
pj, rj = sys.argv[1], sys.argv[2]
if not os.path.exists(pj):
    sys.exit(0)
conf = json.load(open(pj))
rt = json.load(open(rj)) if os.path.exists(rj) else {}
defaults = {
    "appid": "2430930",
    "game_port": int(rt.get("port", 7777)),
    "query_port": int(rt.get("query_port", 27015)),
    "rcon_port": int(rt.get("rcon_port", 27020)),
}
changed = False
for k, v in defaults.items():
    if k not in conf:
        conf[k] = v
        changed = True
if changed:
    tmp = pj + ".tmp"
    json.dump(conf, open(tmp, "w"), indent=2)
    os.replace(tmp, pj)
    print("panel.json ergänzt:", ", ".join(k for k in defaults if k in conf))
PY

chown -R "$ASA_USER":"$ASA_USER" "$PANEL_DIR" /home/asa/asa-launch.sh /home/asa/asa-update.sh
chmod 600 "$PANEL_DIR/panel.json" "$PANEL_DIR/users.json" 2>/dev/null || true
systemctl restart asa-panel.service
echo "Panel aktualisiert und neu gestartet."
