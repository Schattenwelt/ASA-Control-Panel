#!/usr/bin/env bash
###############################################################################
# Repariert eine bestehende ASA-Installation:
#   * installiert libvulkan1 (GE-Proton braucht libvulkan.so.1, sonst crasht der
#     Start mit "libvulkan.so.1: cannot open shared object file")
#   * erlaubt dem Panel, das Journal seiner Units per sudo zu lesen (Server-Log)
#   * nimmt den asa-User zusätzlich in die systemd-journal-Gruppe
#   * startet das Panel neu
# Danach im Panel "Neu starten" drücken – der Server sollte hochkommen.
#
#   sudo bash scripts/fix-deps.sh
###############################################################################
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Bitte als root ausführen." >&2; exit 1; }
ASA_USER="asa"

echo "==> Installiere fehlende Proton-Abhängigkeit (libvulkan1) ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends libvulkan1 || {
    echo "libvulkan1 nicht gefunden – versuche universe zu aktivieren ..."
    apt-get install -y --no-install-recommends software-properties-common
    add-apt-repository -y universe && apt-get update -y
    apt-get install -y --no-install-recommends libvulkan1
}
apt-get install -y --no-install-recommends libvulkan1:i386 2>/dev/null || true

echo "==> Erneuere sudo-Regel (systemctl + journalctl-Lesen fürs Server-Log) ..."
SUDO_FILE=/etc/sudoers.d/asa-panel
cat > "$SUDO_FILE" <<'SUDO'
asa ALL=(root) NOPASSWD: /usr/bin/systemctl enable --now asa.service, /usr/bin/systemctl disable --now asa.service, /usr/bin/systemctl enable asa.service, /usr/bin/systemctl disable asa.service, /usr/bin/systemctl restart asa.service, /usr/bin/systemctl reset-failed asa.service, /usr/bin/systemctl start asa-update.service, /usr/bin/journalctl -u asa.service *, /usr/bin/journalctl -u asa-update.service *
SUDO
chmod 440 "$SUDO_FILE"
visudo -cf "$SUDO_FILE" >/dev/null || { echo "sudoers-Regel ungültig!" >&2; exit 1; }

echo "==> Nehme $ASA_USER in die systemd-journal-Gruppe (Log-Fallback ohne sudo) ..."
usermod -aG systemd-journal "$ASA_USER" || true

echo "==> Starte Panel neu ..."
systemctl restart asa-panel.service || true

echo
echo "Fertig. Jetzt im Panel 'Neu starten' klicken und das Server-Log beobachten."
echo "Falls weiterhin ein Fehler kommt, das Log posten:  journalctl -u asa.service -n 60 --no-pager"
