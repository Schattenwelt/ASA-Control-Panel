# ASA Control Panel (Docker)

A lightweight, self-hosted web panel to run and control an **ARK: Survival
Ascended dedicated server** inside a Proxmox LXC — via **Docker**. The server
itself runs in the well-maintained `ghcr.io/justamply/asa-linux-server` image
(which bundles a working GE-Proton + Steam-Runtime stack), so you avoid the
Proton/Steamworks headaches of a bare-metal setup. The panel controls the
container: start / stop / restart / update, a config editor, **map & mod
management**, RCON (player list, save, clean shutdown, broadcasts), a version /
update check and an optional daily panel self-update.

Interface available in **English and German**.

> Unofficial community project. Not affiliated with Studio Wildcard / Snail
> Games. Server image by JustAmply (based on mschnitzer's work).

## Why Docker

Running ASA (a Windows/DX12 title) directly under Proton in an unprivileged LXC
hits several walls — missing Vulkan, fsync/futex, and ultimately a Steamworks
`abort()` at startup. The Docker image ships a known-good runtime combination
that boots reliably, so this panel drives that container instead of wrestling
Proton by hand.

## Requirements

- A **Proxmox LXC** (Ubuntu 24.04, unprivileged is fine) with **`nesting=1`**
  (host: `pct set <CTID> --features nesting=1`), **~13 GB RAM**, **~40+ GB disk**.
- On the **Proxmox host**: `vm.max_map_count` high enough for UE5:
  ```bash
  echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-asa.conf
  sysctl -p /etc/sysctl.d/99-asa.conf
  ```
- Docker is installed automatically by the installer.

## Installation

Create a fresh container on the host, then inside it:

```bash
git clone https://github.com/Schattenwelt/ASA-Control-Panel.git
cd ASA-Control-Panel
bash install.sh
```

The installer asks for a panel username/password (or run non-interactively with
`PANEL_USER=... PANEL_PASS=... bash install.sh`). Panel port defaults to 80
(`PANEL_PORT=8080 bash install.sh`); game/RCON ports via
`GAME_PORT=7777 RCON_PORT=27020 bash install.sh`; server image via
`ASA_IMAGE=...`.

Open `http://<container-ip>`, pick a map, add CurseForge mod IDs, then **Start**.
The first start downloads SteamCMD + the server files (~15–30 GB) into
`/opt/asa-data` and generates the world — watch progress under **Server-Log** or
`docker logs -f asa-server-1`. Open **7777/UDP** in your firewall.

## How it works

- The server runs as the Docker container **`asa-server-1`** (compose file in
  `/opt/asa-panel/docker/`). Game files, Steam and SteamCMD live in bind-mounts
  under `/opt/asa-data` so the panel can read/write config, logs and version.
- **`asa.service`** (systemd) runs `docker compose up` in the foreground, so the
  panel's Start/Stop/Restart/Autostart work exactly as before — it just wraps
  Docker now. The panel's map/mods/ports/session settings are compiled into
  `ASA_START_PARAMS` on each start.
- **RCON** is published on `127.0.0.1:27020`; the panel connects with the admin
  password from `panel.json`.
- **Update** pulls a newer image; the container updates the game files itself on
  the next start.

## Maps & Mods

Same as before: official `_WP` maps are built in (free), custom/mod maps take a
map code + mod ID. Mods are CurseForge IDs in load order — they go into
`-mods=` in `ASA_START_PARAMS` and the image downloads them on (re)start.

## Ports (fixed & locked)

Game and RCON ports are chosen at install and **locked** in the panel
(`GAME_PORT` / `RCON_PORT`), so they can't drift out of sync with the container's
published ports. RCON is managed by the panel and always on.

## Config editor

The panel edits `GameUserSettings.ini` / `Game.ini` in the container's mounted
config dir (`/opt/asa-data/server-files/ShooterGame/Saved/Config/WindowsServer/`).
The data dir is world-writable inside this private container so the panel and the
container can share those files.

## Auto-update (panel)

```bash
sudo bash scripts/setup-autoupdate.sh            # daily ~04:30
sudo bash scripts/setup-autoupdate.sh --run-now
```
Pulls this repo and redeploys the panel only (not the game container).

## Updating the panel manually

```bash
git pull
sudo bash scripts/update.sh
```

## Project layout

```
install.sh                   Docker-based installer (run once in a fresh LXC)
docker/docker-compose.yml    Compose definition for the ASA container
src/asa-launch.sh            Builds ASA_START_PARAMS + asa.env, runs docker compose up
src/asa-update.sh            docker compose pull
scripts/update.sh            Refresh panel code, restart the panel
scripts/setup-autoupdate.sh  Daily panel self-update timer
src/                         Panel source (Flask app, RCON, i18n, templates, CSS)
```

## systemd services

- `asa.service` — the ASA Docker container (via `docker compose up`)
- `asa-panel.service` — the web panel (waitress)
- `asa-update.service` — `docker compose pull` (oneshot)

## License

MIT — see [LICENSE](LICENSE).
