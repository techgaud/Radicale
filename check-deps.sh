#!/bin/bash
set -euo pipefail

echo "==> Checking dependencies..."

# ─── APT UPDATE ──────────────────────────────────────────────────────────────
# Run once upfront so installs don't fail on a fresh system.
# We use || true so that pre-existing broken repos on the system (e.g. a
# stale Docker or Chrome repo) do not abort our script before we even start.
sudo apt-get update -qq || true

# ─── CURL ────────────────────────────────────────────────────────────────────
if ! command -v curl &>/dev/null; then
  echo "    Installing curl..."
  sudo apt-get install -y curl
else
  echo "    curl: OK ($(curl --version | head -n1))"
fi

# ─── JQ ──────────────────────────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  echo "    Installing jq..."
  sudo apt-get install -y jq
else
  echo "    jq: OK ($(jq --version))"
fi

# ─── NETCAT ──────────────────────────────────────────────────────────────────
if ! command -v nc &>/dev/null; then
  echo "    Installing netcat..."
  sudo apt-get install -y netcat-openbsd
else
  echo "    netcat: OK"
fi

# ─── DOCKER ──────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo "    Installing Docker..."
  sudo rm -f /etc/apt/sources.list.d/docker.list
  sudo rm -f /usr/share/keyrings/docker-archive-keyring.gpg
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  echo "    Docker installed."
  echo "    NOTE: You will need to log out and back in (or run 'newgrp docker')"
  echo "          before running setup.sh, otherwise Docker commands will fail."
else
  echo "    Docker: OK ($(docker --version))"
fi

# ─── DOCKER COMPOSE ──────────────────────────────────────────────────────────
if ! docker compose version &>/dev/null; then
  echo "    Installing Docker Compose plugin..."
  rm -f ~/.docker/cli-plugins/docker-compose
  sudo rm -f /usr/local/lib/docker/cli-plugins/docker-compose
  COMPOSE_VERSION=$(curl -sf https://api.github.com/repos/docker/compose/releases/latest | \
    jq -r '.tag_name')
  mkdir -p ~/.docker/cli-plugins
  curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
    -o ~/.docker/cli-plugins/docker-compose
  chmod +x ~/.docker/cli-plugins/docker-compose
  echo "    Docker Compose installed: $(docker compose version)"
else
  echo "    Docker Compose: OK ($(docker compose version))"
fi

# ─── PYTHON3 ─────────────────────────────────────────────────────────────────
# Required by ingest.py. Uses stdlib only — no pip packages needed.
if ! command -v python3 &>/dev/null; then
  echo "    Installing python3..."
  sudo apt-get install -y python3
else
  echo "    python3: OK ($(python3 --version))"
fi

# ─── GIT ─────────────────────────────────────────────────────────────────────
if ! command -v git &>/dev/null; then
  echo "    Installing git..."
  sudo apt-get install -y git
else
  echo "    git: OK ($(git --version))"
fi

# ─── CLOUDFLARED ─────────────────────────────────────────────────────────────
if ! command -v cloudflared &>/dev/null; then
  echo "    Installing cloudflared..."
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | \
    sudo tee /usr/share/keyrings/cloudflare-main.gpg > /dev/null
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] \
https://pkg.cloudflare.com/cloudflared jammy main" | \
    sudo tee /etc/apt/sources.list.d/cloudflared.list
  sudo apt-get update -qq
  sudo apt-get install -y cloudflared
else
  echo "    cloudflared: OK ($(cloudflared --version))"
fi

echo ""
echo "==> All dependencies satisfied."

# ─── DOCKER GROUP WARNING ────────────────────────────────────────────────────
if ! groups "$USER" | grep -q docker; then
  echo ""
  echo "WARNING: Your user is not yet in the docker group."
  echo "         Run 'newgrp docker' or log out and back in before running setup.sh"
fi
