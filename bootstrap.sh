#!/usr/bin/env bash
# Prepare Ubuntu Server as a LAN media server host.
# Target: Dell Latitude E6510, i5-560M, 8GB RAM.
#   SSD  -> OS (/), Docker, /opt/appdata   (fast, small, random I/O)
#   HDD  -> /data  (1TB WD10SPZX, SMR, in the caddy: media + torrents only)
#
#   sudo bash bootstrap.sh
#
# THIS SCRIPT DOES NOT START THE STACK. It prepares the host only. You still
# need to edit .env and run `docker compose up -d` yourself, because the API
# keys the stack wants do not exist until the containers have run once.
#
set -euo pipefail

# Run the stack as the existing login account rather than a dedicated service
# user. The Ubuntu installer already took UID 1000, and on a single-user box a
# separate `media` account just means needing sudo every time you touch a file.
MEDIA_USER="${SUDO_USER:-$USER}"
APPDATA=/opt/appdata
STACK=/opt/media
DATA=/data

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!!  %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

# ---------------------------------------------------------------------------
log "Base packages"
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg git tmux \
  smartmontools ethtool htop iotop sysstat \
  unattended-upgrades

# ---------------------------------------------------------------------------
log "Docker from the upstream repo (NOT the snap)"
# The snap build is strictly confined and mangles bind mounts. That class of
# problem is the most likely reason ZimaOS kept falling over.
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable
EOF
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
systemctl restart docker

# ---------------------------------------------------------------------------
log "Service account and directory layout"
if ! id -u "$MEDIA_USER" >/dev/null 2>&1; then
  echo "Cannot resolve a user to own these files. Run with sudo, not as root."
  exit 1
fi
MEDIA_UID=$(id -u "$MEDIA_USER")
MEDIA_GID=$(id -g "$MEDIA_USER")
echo "Running the stack as $MEDIA_USER (uid $MEDIA_UID, gid $MEDIA_GID)."
echo "These MUST match PUID and PGID in $STACK/.env"

# Let this account drive Docker without sudo.
getent group docker >/dev/null && usermod -aG docker "$MEDIA_USER"

# incomplete/ lives UNDER $DATA on purpose. Putting it on the SSD would make
# every completed download a cross-filesystem copy instead of a rename.
mkdir -p "$STACK"
# Create every appdata dir up front, owned by the stack user. Otherwise Docker
# creates missing bind-mount sources as root and the containers cannot write.
mkdir -p "$APPDATA"/{qbittorrent,prowlarr,sonarr,radarr,bazarr,jellyfin,seerr,recyclarr,homepage}
mkdir -p "$DATA"/torrents/{incomplete,movies,tv} "$DATA"/media/{movies,tv}
chown -R "$MEDIA_UID":"$MEDIA_GID" "$APPDATA" "$STACK"
# Existing media on $DATA is left alone: no recursive chown/chmod (it would be
# slow on an SMR disk and would mark every media file executable). Only the
# directory skeleton is touched.
for d in "$DATA" "$DATA"/torrents "$DATA"/torrents/{incomplete,movies,tv} \
         "$DATA"/media "$DATA"/media/{movies,tv}; do
  chown "$MEDIA_UID":"$MEDIA_GID" "$d"
  chmod 775 "$d"
done
if [[ -n "$(find "$DATA/media" -mindepth 2 -maxdepth 2 -not -user "$MEDIA_UID" -print -quit 2>/dev/null)" ]]; then
  warn "Existing files under $DATA/media are not owned by uid $MEDIA_UID."
  warn "Fix with: sudo chown -R $MEDIA_UID:$MEDIA_GID $DATA (slow on SMR, one-off)."
fi

# ---------------------------------------------------------------------------
log "Verifying the hardlink precondition"
# If these report different devices, every import becomes a full copy.
t=$(stat -c %d "$DATA/torrents")
m=$(stat -c %d "$DATA/media")
i=$(stat -c %d "$DATA/torrents/incomplete")
if [[ "$t" == "$m" && "$t" == "$i" ]]; then
  echo "OK: one filesystem. Hardlink imports and rename-on-complete will work."
else
  warn "Different devices under $DATA. Fix mounts before importing anything."
fi

# Prove link() actually succeeds, rather than just trusting st_dev.
if ( cd "$DATA" && touch torrents/.lntest && ln torrents/.lntest media/.lntest ) 2>/dev/null; then
  echo "OK: link() succeeded across torrents/ and media/"
  rm -f "$DATA"/torrents/.lntest "$DATA"/media/.lntest
else
  warn "link() failed. Imports will copy instead of hardlink."
fi

# ---------------------------------------------------------------------------
log "Reserve headroom on the root filesystem"
# Default ext4 holds back 5% for root-owned writes. On a large partition
# that is wasteful, but some reserve matters: it is what lets journald and
# Docker keep writing when the filesystem is otherwise full.
ROOTDEV=$(findmnt -no SOURCE /)
tune2fs -m 2 "$ROOTDEV" >/dev/null 2>&1 && echo "root reserve set to 2%" || true

# If /data is its own partition, it needs almost no reserve: nothing
# system-critical writes there.
if mountpoint -q "$DATA"; then
  DATADEV=$(findmnt -no SOURCE "$DATA")
  tune2fs -m 1 "$DATADEV" >/dev/null 2>&1 && echo "data reserve set to 1%" || true
else
  warn "$DATA is not a separate mount. That is a valid choice, but set a"
  warn "minimum free space in Sonarr and Radarr so a full disk cannot take"
  warn "down Docker and journald along with it."
fi

# ---------------------------------------------------------------------------
log "Laptop: do not sleep when the lid closes"
mkdir -p /etc/systemd/logind.conf.d
cat >/etc/systemd/logind.conf.d/99-server.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
HandleLidSwitchExternalPower=ignore
EOF
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
systemctl restart systemd-logind || true

if ! grep -q consoleblank /etc/default/grub; then
  sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 consoleblank=60"/' \
    /etc/default/grub
  update-grub
fi

# ---------------------------------------------------------------------------
log "Kernel tuning for 8GB RAM and a slow SMR data disk"
cat >/etc/sysctl.d/99-media.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
# Flush dirty pages early and often. Large dirty batches hitting an SMR drive
# cause multi-second stalls that look like the whole machine has hung.
vm.dirty_background_ratio=5
vm.dirty_ratio=10
vm.dirty_expire_centisecs=1500
EOF
sysctl --system >/dev/null

cat >/etc/udev/rules.d/60-scheduler.rules <<'EOF'
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline"
EOF
udevadm control --reload && udevadm trigger --subsystem-match=block || true

# ---------------------------------------------------------------------------
log "SMART monitoring"
sed -i 's/^start_smartd=no/start_smartd=yes/' /etc/default/smartmontools 2>/dev/null || true
systemctl enable --now smartd || true

# ---------------------------------------------------------------------------
log "Security updates only, no automatic reboots"
cat >/etc/apt/apt.conf.d/51-media-unattended <<'EOF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF
systemctl enable --now unattended-upgrades

# ---------------------------------------------------------------------------
log "Tailscale (remote access, nothing exposed to the internet)"
if ! command -v tailscale >/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled || true

# ---------------------------------------------------------------------------
log "Host is ready. The stack is NOT running yet."
cat <<EOF

Do these in order (full walkthrough in SETUP.md):

  1. Log out and back in (docker group), then clone the repo:
       git clone <repo> $STACK && cd $STACK
       cp .env.example .env && chmod 600 .env
       # set PUID=$MEDIA_UID PGID=$MEDIA_GID DOCKER_GID=$(getent group docker | cut -d: -f3), SERVER_IP, QBT_PASS

  2. Copy app configs, then start:
       cp homepage/*.yaml $APPDATA/homepage/
       mkdir -p $APPDATA/recyclarr/configs && cp recyclarr/*.yml $APPDATA/recyclarr/configs/
       chown -R $MEDIA_UID:$MEDIA_GID $APPDATA/homepage $APPDATA/recyclarr
       docker compose up -d

  3. Join the tailnet (opens a login URL):
       sudo tailscale up --ssh

  4. Confirm the NIC is at gigabit:
       ethtool eth0 | grep Speed
EOF
