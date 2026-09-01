# ASA Control Panel

A lightweight, self-hosted web panel to install, configure and control an
**ARK: Survival Ascended dedicated server** inside a Proxmox LXC container —
with a login-protected UI, live status, one-click update, a config editor,
**map and mod management** and RCON (player list, save, clean shutdown,
broadcasts).

ASA has no native Linux server, so this panel runs the Windows server binary
(`ArkAscendedServer.exe`) through **GE-Proton**. Mods are handled the ASA way:
you list **CurseForge** IDs and the server downloads them itself on start.

The interface is available in **English and German** (switchable at the top).

> Unofficial community project. Not affiliated with Studio Wildcard / Snail
> Games. "ARK: Survival Ascended" is a trademark of its respective owner.

## Features

- Server control: **start / restart / stop** and **update** (SteamCMD, app 2430930)
- **Runs via Proton**: the installer sets up GE-Proton and a compat prefix; the
  start wrapper launches the `.exe` through it — you don't touch any of that
- **Reboot-aware**: the server only comes back after a reboot if it was running
  before (start = autostart on, stop = off); the LXC itself starts via Proxmox
  `onboot`
- **Map management**: pick official `_WP` maps with one click, add custom/mod
  maps (map code + optional mod ID). ASA's official maps are free.
- **Mod management**: enter **CurseForge mod IDs** in load order, reorder and
  remove them. No manual download — ASA fetches and installs mods itself when
  they're passed via `-mods=` (see [Mods](#mods)).
- **Launch parameters** (session name, max players, ports, BattlEye, extra args)
- **Locked ports**: game, query and RCON ports are fixed at install time (`GAME_PORT` /
  `QUERY_PORT` / `RCON_PORT`) and locked in the panel — the launch form and config
  editor show them read-only and enforce them on save, so a stray edit can't change
  the port the firewall forwards to
- **Version & update check**: the dashboard shows the installed build id and a
  *Check for updates* button that compares it against the latest public build id
  (`api.steamcmd.net`)
- **Panel self-update**: an optional daily systemd timer pulls this repo and
  redeploys only the panel (see [Auto-update](#auto-update))
- **Config editor** for both `GameUserSettings.ini` **and** `Game.ini` — grouped
  fields per section *and* a raw editor
- **RCON, server-local**: uses the ServerAdminPassword; live player list with
  **kick / ban**, save world, "save & stop" and broadcasts
- **Connect box** on the dashboard: shows the session name to search for in the
  in-game server list plus the direct-connect line (`open IP:port`), and
  auto-detects the public IP
- **Multiple user accounts**: create / reset / delete; all equal
- Runs as an unprivileged user behind a narrow `sudo` allow-list

## Requirements

- A **Proxmox LXC container** (Ubuntu 24.04, unprivileged is fine),
  **12–16 GB RAM recommended** (min. 10 GB; more depending on map/mods),
  **~60+ GB disk** (ASA is large)
- Root access inside the container
- On the **Proxmox host**: `vm.max_map_count` must be high enough (ASA/UE5 maps
  a huge number of memory regions). If the installer warns, set it on the host:
  ```bash
  echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-asa.conf
  sysctl -p /etc/sysctl.d/99-asa.conf
  ```
  This is host-wide and cannot be set from inside an unprivileged LXC. Giving the
  container some swap (`pct set <VMID> --swap 8192`) helps absorb the memory

- The installer also installs a software Vulkan driver (`mesa-vulkan-drivers`, lavapipe). ASA is a UE5/DX12 title that Proton translates to Vulkan; in a GPU-less container the server needs a Vulkan device to get past render init, even though a dedicated server renders nothing. `libvulkan1` alone (the loader) is not enough.
  spike during first-time world generation.

## Installation

Create the container on the Proxmox host (example):

```bash
pct create 211 local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
  --hostname asa --cores 6 --memory 16384 --swap 8192 \
  --rootfs local-lvm:80 --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --unprivileged 1 --features nesting=1 --onboot 1
pct start 211 && pct enter 211
```

Inside the container:

```bash
git clone https://github.com/Schattenwelt/ASA-Control-Panel.git
cd ASA-Control-Panel
bash install.sh
```

The installer asks for a panel username and password (or run it non-interactively
with `PANEL_USER=... PANEL_PASS=... bash install.sh`). The panel listens on
**port 80** by default; override with `PANEL_PORT=8080 bash install.sh`. Pin a
specific GE-Proton release with `PROTON_VERSION=GE-Proton9-20 bash install.sh`
(default: latest).

Then open `http://<container-ip>`, pick a map under **Maps**, add CurseForge IDs
under **Mods**, review settings under **Config**, and hit **Start**. The first
start takes a while (Proton prefix warm-up + world generation).

Port to open in your firewall: **7777/UDP** (game). ASA uses the game port for
the server list (EOS/crossplay) — no separate Steam query port is required.

## Maps

The official ASA maps are built in: The Island, The Center, Scorched Earth,
Aberration, Extinction, Ragnarok and Astraeos — all as World-Partition maps with
the `_WP` suffix, and all **free** (unlike ARK: SE there is no per-map DLC to
own).

For a mod map, enter the **map code** (e.g. `Svartalfheim_WP`) and the **mod ID**;
the mod must also be listed under Mods so the server pulls it in.

## Mods

Mod handling on ARK: Survival Ascended is much simpler than on ARK: Survival
Evolved. ASA mods live on **CurseForge**, and the server **downloads and installs
them itself** when they are passed on the command line via `-mods=<id,id,...>`.
There is no Steam Workshop, no `.z` extraction and no `ActiveMods=` line.

Workflow: add the CurseForge mod ID under **Mods**, order the list (load order
matters for dependent mods — map mods generally first), then **restart the
server**. On the next start ASA fetches any new mods automatically. Removing a
mod and restarting drops it.

You can find a mod's numeric ID on its CurseForge page; the **CurseForge** link
next to each entry opens `curseforge.com/projects/<id>`.

## Auto-update

Enable a daily systemd timer that pulls this repo and redeploys the panel (only the
panel is restarted, not the game server; your accounts, maps, mods and config stay):

```bash
sudo bash scripts/setup-autoupdate.sh            # runs daily ~04:30
sudo bash scripts/setup-autoupdate.sh --run-now  # and update immediately
```

Custom repo/time: `PANEL_REPO_URL=... UPDATE_TIME=03:15 sudo bash scripts/setup-autoupdate.sh`.
Disable: `sudo systemctl disable --now asa-panel-update.timer`. The panel footer shows
the running version.

## Ports (fixed & locked)

The game, query and RCON ports are chosen at install time and then **locked** in the
panel so they can't drift out of sync with your firewall forwarding:

```bash
GAME_PORT=7777 QUERY_PORT=27015 RCON_PORT=27020 bash install.sh
```

They are written to `panel.json`, seeded into `GameUserSettings.ini`, and enforced by
the panel: the launch form shows them read-only, the config editor locks `RCONPort`,
and both structured and raw saves re-assert the fixed RCON port. Open **7777/UDP**
(or your chosen game port) in the firewall.

## Updating the panel

```bash
git pull
sudo bash scripts/update.sh
```

Users, maps, mods and config are left untouched.

## Repairing RCON

If RCON is unreachable:

```bash
sudo bash scripts/repair.sh
```

Sets `RCONEnabled=True`, the RCON port and, if missing, a `ServerAdminPassword`,
restarts the server and waits for the port.

## Project layout

```
install.sh            Full installer (run once in a fresh container)
scripts/update.sh     Refresh panel code from the repo, restart the panel
scripts/repair.sh     Ensure RCON is set up in GameUserSettings.ini
scripts/setup-autoupdate.sh  Install the daily panel self-update timer
src/                  Panel source (Flask app, RCON, i18n, templates, CSS)
src/asa-launch.sh     Start wrapper (builds the start line, runs the .exe via Proton)
src/asa-update.sh     SteamCMD update (Windows depots) + save backups
```

## Data storage (in the panel directory /opt/asa-panel)

- `panel.json` – base config (paths, service names, secret key)
- `users.json` – user accounts (hashed passwords)
- `runtime.json` – launch parameters: map, mods, ports, public address, extra args
- `maps.json` – custom/mod maps
- `mods.json` – optional display names for mod IDs

## systemd services

- `asa.service` – the game server (started via `asa-launch.sh` through Proton)
- `asa-panel.service` – the web panel (waitress)
- `asa-update.service` – SteamCMD update (oneshot)

## How the Proton launch works

`asa-launch.sh` reads `runtime.json`, pulls the `ServerAdminPassword` from the
INI, then execs:

```
$PROTON_DIR/proton run ArkAscendedServer.exe \
  <Map>_WP?listen?SessionName=…?Port=…?QueryPort=…?RCONEnabled=True?RCONPort=…?ServerAdminPassword=… \
  -log -WinLiveMaxPlayers=<N> -mods=<ids> [-NoBattlEye] [extra args]
```

with `STEAM_COMPAT_DATA_PATH` (the prefix) and `STEAM_COMPAT_CLIENT_INSTALL_PATH`
exported. Note the ASA-specific bits: **max players via `-WinLiveMaxPlayers=`**
(not `?MaxPlayers=`) and **mods via `-mods=`**.

## Security notes

Passwords are hashed (Werkzeug) and all mutating actions are CSRF-protected. The
panel serves plain HTTP — put it behind a reverse proxy with TLS for access beyond
your LAN. `panel.json` and `users.json` hold sensitive data and are created with
`600` (git-ignored).

## License

MIT — see [LICENSE](LICENSE).
