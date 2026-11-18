# Homelab

Docker Compose media server (Dell Latitude E6510, Ubuntu Server). Built up one piece at a time.

## Stack

| Service | Port | Role |
|---|---|---|
| qBittorrent | 8080 | Downloads |
| Prowlarr | 9696 | Indexer manager |
| Sonarr | 8989 | TV |
| Radarr | 7878 | Movies |
| Bazarr | 6767 | Subtitles |
| Byparr | - | Cloudflare solver (internal only) |
| Jellyfin | 8096 | Media server |
| Seerr | 5055 | Requests |
| Recyclarr | - | TRaSH quality profile sync |
| Dozzle | 8888 | Container logs |
| WUD | 3002 | Image update checker |
| Homepage | 80 | Dashboard |

## Storage

- **SSD** (`/`): OS, Docker, `/opt/appdata` (configs and databases)
- **HDD** (`/data`, mounted by UUID): `media/` and `torrents/` only, on one filesystem so imports hardlink instead of copy

## Dashboard

Homepage config lives in `homepage/` and is copied to `/opt/appdata/homepage`. API keys come from `.env` via `HOMEPAGE_VAR_*`, never from the YAML.

## Remote access

Tailscale runs on the host (installed by `bootstrap.sh`), not in a container.

## Setup

```bash
sudo bash bootstrap.sh
cp .env.example .env && chmod 600 .env   # edit it
cp homepage/*.yaml /opt/appdata/homepage/
mkdir -p /opt/appdata/recyclarr/configs && cp recyclarr/*.yml /opt/appdata/recyclarr/configs/
docker compose up -d
```

First-run wiring of the apps is in [SETUP.md](SETUP.md).
