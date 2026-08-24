#!/bin/sh
set -e

DEPLOY_DIR="${DEPLOY_DIR:-/opt/monitoring}"

cd "$DEPLOY_DIR"

# Regenerate Dozzle's users.yml from MONITORING_DOZZLE_USERNAME/PASSWORD,
# passed in directly as shell env by the CI SSH step (not read back from
# .env - sourcing that file as shell breaks the moment a secret contains a
# shell-special character). Never committed; bcrypt-hashed by `dozzle generate`.
mkdir -p "$DEPLOY_DIR/data/dozzle"
docker run --rm amir20/dozzle generate "$MONITORING_DOZZLE_USERNAME" \
  --password "$MONITORING_DOZZLE_PASSWORD" \
  --name "$MONITORING_DOZZLE_USERNAME" > "$DEPLOY_DIR/data/dozzle/users.yml"
chmod 600 "$DEPLOY_DIR/data/dozzle/users.yml"

docker compose pull
docker compose up -d --remove-orphans
docker image prune -f

if ! command -v caddy >/dev/null 2>&1; then
  sudo apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
  sudo apt-get update -qq
  sudo apt-get install -y -qq caddy
fi

sudo mkdir -p /etc/caddy/sites
sudo cp "$DEPLOY_DIR/deploy/Caddyfile" /etc/caddy/sites/home-monitoring.Caddyfile

if ! grep -q '^import sites/\*$' /etc/caddy/Caddyfile 2>/dev/null; then
  echo 'import sites/*' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi

sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
