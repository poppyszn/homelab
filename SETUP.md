# First-run setup

Run `bootstrap.sh` and `docker compose up -d` first (see README). Then wire the apps in this order. All paths below are **inside the containers**.

```
/data
├── torrents/        qBittorrent downloads (incomplete/, tv/, movies/)
└── media/           the library (tv/, movies/)
```

`torrents/` and `media/` must stay on the same filesystem (the HDD), so imports hardlink instead of copy.

## 1. qBittorrent — http://SERVER_IP:8080
- First login: user `admin`, temporary password in `docker logs qbittorrent`.
- Tools → Options → Web UI: set the username and password to match `QBT_USER` / `QBT_PASS` in `.env`.
- Downloads:
  - Default Save Path: `/data/torrents`
  - Keep incomplete torrents in: `/data/torrents/incomplete`
  - Pre-allocate disk space: on (one sequential write suits an SMR disk)
- Categories (right-click in the sidebar):
  - `tv-sonarr` → `/data/torrents/tv`
  - `radarr` → `/data/torrents/movies`

## 2. Sonarr / Radarr — :8989 / :7878
- Settings → Media Management:
  - Root folder: `/data/media/tv` (Sonarr), `/data/media/movies` (Radarr)
  - **Use Hardlinks instead of Copy**: on
- Settings → Download Clients → qBittorrent: host `qbittorrent`, port `8080`, your login, category `tv-sonarr` (Sonarr) or `radarr` (Radarr).
- Settings → General: copy the **API Key** into `.env`.

## 3. Prowlarr — :9696
- Settings → Apps: add Sonarr (`http://sonarr:8989`) and Radarr (`http://radarr:7878`) with their API keys. Prowlarr URL: `http://prowlarr:9696`.
- Add your indexers. They sync to Sonarr and Radarr automatically.
- Cloudflare-protected indexers only: Settings → Indexers → add a **FlareSolverr** proxy with host `http://byparr:8191` and a tag, then give that tag to just those indexers.
- Copy the API Key into `.env`.

## 4. Bazarr — :6767
- Settings → Sonarr / Radarr: hosts `sonarr` / `radarr`, their API keys.
- Settings → Languages: set your language profile and subtitle providers.
- Copy the API Key into `.env`.

## 5. Jellyfin — :8096
- Run the wizard. Libraries: TV → `/data/media/tv`, Movies → `/data/media/movies`.
- Dashboard → Playback → Transcoding: **Hardware acceleration: None** (the CPU cannot encode; use direct play).
- Dashboard → API Keys: create one for Homepage and put it in `.env`.

## 6. Seerr — :5055
- Sign in with Jellyfin (`http://jellyfin:8096`).
- Add Sonarr and Radarr (hosts `sonarr` / `radarr`, API keys, root folders as above).
- Settings → General: copy the API Key into `.env`.

## 7. Recyclarr
Configs live in `recyclarr/` in this repo and are copied to `/opt/appdata/recyclarr/configs/` (done in the bootstrap steps). They use the TRaSH **WEB-1080p** profile for Sonarr and **HD Bluray + WEB** for Radarr, with `!env_var` for the API keys.

After Sonarr and Radarr keys are in `.env` and the containers are recreated (step 8):
```bash
docker exec recyclarr recyclarr sync --preview   # dry run, changes nothing
docker exec recyclarr recyclarr sync             # apply now (otherwise nightly at 04:00)
```
If you already made a quality profile by hand with the same name, don't add the `trash_id` blindly: Recyclarr would create a duplicate. Delete or rename the manual one first.

Optional: set Jellyfin-friendly file naming. Run `docker exec recyclarr recyclarr list naming sonarr` (and `radarr`), then uncomment `media_naming` in the config with the keys you pick.

## 8. Apply the keys
After filling the keys in `.env`:
```bash
docker compose up -d
```
This recreates Homepage and Recyclarr with the new values. Homepage is at http://SERVER_IP (port 80), WUD (updates) at :3002, Dozzle (logs) at :8888.

## 9. Check hardlinks work
Import a download, then compare inodes. The link count should be 2 and the inode numbers equal:
```bash
ls -li /data/torrents/tv/* /data/media/tv/*/*
```

## 10. Tailscale
```bash
sudo tailscale up --ssh
```
Open the printed URL to log in. From any device on your tailnet, use the server's Tailscale name or IP in place of `SERVER_IP`.
