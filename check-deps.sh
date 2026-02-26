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

# ─── DOCKER ──────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo "    Installing Docker..."
  # Remove any stale or malformed Docker apt repo files left by previous
  # install attempts before running the official installer.
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
# Install directly from GitHub releases to guarantee the correct architecture
# binary. The apt package can install the wrong arch on some Ubuntu setups.
if ! docker compose version &>/dev/null; then
  echo "    Installing Docker Compose plugin..."
  # Remove any broken existing binary first
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

# ─── GPG ────────────────────────────────────────────────────────────────────
if ! command -v gpg &>/dev/null; then
  echo "    Installing gpg..."
  sudo apt-get install -y gnupg
else
  echo "    gpg: OK ($(gpg --version | head -n1))"
fi

# ─── PASS ────────────────────────────────────────────────────────────────────
# pass is the password manager used by Proton Bridge on Linux to store
# credentials. It requires GPG to be installed first.
if ! command -v pass &>/dev/null; then
  echo "    Installing pass..."
  sudo apt-get install -y pass
else
  echo "    pass: OK ($(pass version))"
fi

# ─── PYTHON3 AND IMAPCLIENT ──────────────────────────────────────────────────
# Required by ics-sync.sh to connect to Bridge's local IMAP and process
# email attachments.
if ! command -v python3 &>/dev/null; then
  echo "    Installing python3..."
  sudo apt-get install -y python3 python3-pip
else
  echo "    python3: OK ($(python3 --version))"
fi

if ! python3 -c "import imapclient" &>/dev/null; then
  echo "    Installing imapclient..."
  pip3 install imapclient --break-system-packages
else
  echo "    imapclient: OK"
fi

if ! python3 -c "import icalendar" &>/dev/null; then
  echo "    Installing icalendar..."
  pip3 install icalendar --break-system-packages
else
  echo "    icalendar: OK"
fi

# ─── GO ────────────────────────────────────────────────────────────────────
# Required to build goimapnotify from source. goimapnotify is hosted on
# GitLab and does not publish pre-built binaries, so we build it via
# go install.
if ! command -v go &>/dev/null; then
  echo "    Installing Go..."
  GO_VERSION=$(curl -sf https://go.dev/dl/?mode=json | jq -r '.[0].version')
  curl -fsSL "https://dl.google.com/go/${GO_VERSION}.linux-amd64.tar.gz" \
    -o /tmp/go.tar.gz
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf /tmp/go.tar.gz
  rm /tmp/go.tar.gz
  # Add Go to PATH for the rest of this script
  export PATH="$PATH:/usr/local/go/bin"
  # Persist it for future sessions
  if ! grep -q '/usr/local/go/bin' ~/.profile; then
    echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
    echo 'export PATH=$PATH:$(go env GOPATH)/bin' >> ~/.profile
  fi
  echo "    Go installed: $(go version)"
else
  echo "    Go: OK ($(go version))"
fi

# Ensure GOPATH bin is in PATH for this session
export PATH="$PATH:$(go env GOPATH)/bin"

# ─── GOIMAPNOTIFY ────────────────────────────────────────────────────────────
# Holds an IMAP IDLE connection open against Bridge and fires ics-sync.py
# the moment new mail arrives in the watched folder.
# Source: https://gitlab.com/shackra/goimapnotify
if ! command -v goimapnotify &>/dev/null; then
  echo "    Installing goimapnotify..."
  go install gitlab.com/shackra/goimapnotify@latest
  # Symlink into /usr/local/bin so it is available system-wide
  sudo ln -sf "$(go env GOPATH)/bin/goimapnotify" /usr/local/bin/goimapnotify
  echo "    goimapnotify installed."
else
  echo "    goimapnotify: OK"
fi

# ─── PROTON BRIDGE ───────────────────────────────────────────────────────────
# Bridge exposes a local IMAP/SMTP interface that decrypts Proton Mail on
# the fly. Requires a paid Proton plan.
if ! command -v proton-bridge &>/dev/null; then
  echo "    Installing Proton Bridge..."
  BRIDGE_VERSION=$(curl -sf https://api.github.com/repos/ProtonMail/proton-bridge/releases/latest | \
    jq -r '.tag_name' | sed 's/^v//')
  curl -fsSL "https://github.com/ProtonMail/proton-bridge/releases/download/v${BRIDGE_VERSION}/proton-bridge_${BRIDGE_VERSION}-1_amd64.deb" \
    -o /tmp/proton-bridge.deb
  sudo dpkg -i /tmp/proton-bridge.deb || sudo apt-get install -f -y
  rm /tmp/proton-bridge.deb
else
  echo "    Proton Bridge: OK"
fi

# ─── GIT ────────────────────────────────────────────────────────────────────
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

# ─── DOCKER GROUP WARNING ─────────────────────────────────────────────────────
if ! groups "$USER" | grep -q docker; then
  echo ""
  echo "WARNING: Your user is not yet in the docker group."
  echo "         Run 'newgrp docker' or log out and back in before running setup.sh"
fi
