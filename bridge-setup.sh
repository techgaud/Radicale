#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# bridge-setup.sh
#
# One-time setup script that:
#   1. Generates a GPG key pair using the passphrase from config.env
#   2. Initialises pass with that key
#   3. Walks through the interactive Proton Bridge CLI login
#   4. Lists available IMAP folders and confirms the watched folder
#   5. Writes Bridge credentials back to config.env
#   6. Registers Bridge as a systemd user service
#   7. Writes the goimapnotify config
#   8. Registers goimapnotify as a systemd user service
#
# Run this once after check-deps.sh. Do not run it again unless you are
# doing a clean reinstall — it will overwrite your GPG key and pass store.
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# LOAD CONFIG
# ─────────────────────────────────────────────────────────────────────────────
CONFIG_FILE="${1:-config.env}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found: $CONFIG_FILE"
  echo "Usage: ./bridge-setup.sh [path/to/config.env]"
  exit 1
fi

echo "==> Loading config from ${CONFIG_FILE}..."
source "$CONFIG_FILE"

required_vars=(PROTON_EMAIL PROTON_FOLDER GPG_PASSPHRASE RADICALE_CALENDAR_URL RADICALE_USER RADICALE_PASS ICS_SYNC_LOG)
missing=0
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} is not set in ${CONFIG_FILE}"
    missing=1
  fi
done
[[ $missing -eq 1 ]] && exit 1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Generate GPG key
# We generate a non-expiring RSA 4096 key using the passphrase from config.env.
# The key is used by pass to encrypt Bridge credentials at rest.
# gpg-agent will be configured to pre-load the passphrase so that Bridge
# and ics-sync.py can run unattended without prompting.
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Generating GPG key for ${PROTON_EMAIL}..."

EXISTING_KEY=$(gpg --list-keys "${PROTON_EMAIL}" 2>/dev/null | grep -c "pub" || true)

if [[ "$EXISTING_KEY" -gt 0 ]]; then
  echo "    GPG key already exists for ${PROTON_EMAIL}, skipping generation."
else
  GPG_BATCH_FILE=$(mktemp)
  cat > "$GPG_BATCH_FILE" <<EOF
%echo Generating GPG key for Proton Bridge
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: Proton Bridge
Name-Email: ${PROTON_EMAIL}
Expire-Date: 0
Passphrase: ${GPG_PASSPHRASE}
%commit
%echo GPG key generation complete
EOF

  gpg --batch --gen-key "$GPG_BATCH_FILE"
  rm -f "$GPG_BATCH_FILE"
  echo "    GPG key generated."
fi

GPG_KEY_ID=$(gpg --list-keys --with-colons "${PROTON_EMAIL}" | \
  awk -F: '/^fpr/ { print $10; exit }')
echo "    Key fingerprint: ${GPG_KEY_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Configure gpg-agent to cache the passphrase
# default-cache-ttl and max-cache-ttl are set to 0 to cache indefinitely.
# allow-preset-passphrase enables pre-loading the passphrase at login so
# unattended processes like Bridge and ics-sync.py never prompt for it.
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Configuring gpg-agent..."

mkdir -p ~/.gnupg
chmod 700 ~/.gnupg

cat > ~/.gnupg/gpg-agent.conf <<EOF
default-cache-ttl 0
max-cache-ttl 0
allow-preset-passphrase
EOF

gpgconf --kill gpg-agent
gpg-agent --daemon --allow-preset-passphrase 2>/dev/null || true

KEYGRIP=$(gpg --with-keygrip --list-keys "${PROTON_EMAIL}" | \
  awk '/Keygrip/ { print $3; exit }')

/usr/lib/gnupg/gpg-preset-passphrase --preset "${KEYGRIP}" <<< "${GPG_PASSPHRASE}"
echo "    gpg-agent configured and passphrase pre-loaded."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — Initialise pass
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Initialising pass with key ${GPG_KEY_ID}..."

if [[ -d ~/.password-store ]]; then
  echo "    pass store already exists, skipping init."
else
  pass init "${GPG_KEY_ID}"
  echo "    pass initialised."
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Interactive Proton Bridge login
# This is the one step that cannot be automated. Bridge needs your Proton
# credentials and your 2FA TOTP code entered interactively.
# After logging in, run 'info' to confirm Bridge is running and note the
# IMAP port and Bridge-generated IMAP password, then type 'exit'.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  MANUAL STEP REQUIRED: Proton Bridge login"
echo ""
echo "  Bridge will now start in CLI mode. You will be prompted for:"
echo "    1. Your Proton Mail email address"
echo "    2. Your Proton Mail password"
echo "    3. Your 2FA TOTP code"
echo ""
echo "  After logging in:"
echo "    - Type 'info' to see the IMAP port and generated IMAP password"
echo "    - Note both values down, you will need to enter them next"
echo "    - Type 'exit' to return to this script"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -rp "Press Enter when ready to start Bridge login..."

proton-bridge --cli

echo ""
read -rp "Enter the IMAP port Bridge reported (default 1143): " BRIDGE_IMAP_PORT
BRIDGE_IMAP_PORT="${BRIDGE_IMAP_PORT:-1143}"

read -rp "Enter the IMAP password Bridge generated for your account: " BRIDGE_IMAP_PASS

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4b — List available IMAP folders and confirm the watched folder
# Connects to Bridge's local IMAP and prints every available folder so you
# can confirm the exact name and capitalisation of the folder you want to
# watch. The folder name in config.env must match exactly what Bridge reports.
# If the folder you want does not exist yet, create it in Proton Mail first
# and then re-run this script.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Listing available IMAP folders from Bridge..."

python3 - <<PYEOF
import sys
try:
    from imapclient import IMAPClient
except ImportError:
    print("ERROR: imapclient not installed. Run check-deps.sh first.")
    sys.exit(1)

try:
    with IMAPClient("127.0.0.1", port=${BRIDGE_IMAP_PORT}, ssl=False) as client:
        client.login("${PROTON_EMAIL}", "${BRIDGE_IMAP_PASS}")
        folders = client.list_folders()
        print("")
        print("    Available folders:")
        for flags, delimiter, name in sorted(folders, key=lambda x: x[2]):
            print(f"      {name}")
        print("")
except Exception as e:
    print(f"ERROR: Could not list folders: {e}")
    sys.exit(1)
PYEOF

echo "    The folder you want to watch is currently set to: ${PROTON_FOLDER}"
echo ""
read -rp "Press Enter to keep '${PROTON_FOLDER}', or type a different folder name: " FOLDER_INPUT
if [[ -n "$FOLDER_INPUT" ]]; then
  PROTON_FOLDER="$FOLDER_INPUT"
  sed -i "s|^PROTON_FOLDER=.*|PROTON_FOLDER=\"${PROTON_FOLDER}\"|" "${CONFIG_FILE}"
  echo "    PROTON_FOLDER updated to: ${PROTON_FOLDER}"
else
  echo "    Keeping PROTON_FOLDER as: ${PROTON_FOLDER}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4c — Write Bridge credentials back to config.env
# Saves the port and password so ics-sync.py can read them without arguments.
# Uses sed to replace the placeholder values already in config.env.
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Writing Bridge credentials back to ${CONFIG_FILE}..."
sed -i "s|^BRIDGE_IMAP_PORT=.*|BRIDGE_IMAP_PORT=\"${BRIDGE_IMAP_PORT}\"|" "${CONFIG_FILE}"
sed -i "s|^BRIDGE_IMAP_PASS=.*|BRIDGE_IMAP_PASS=\"${BRIDGE_IMAP_PASS}\"|" "${CONFIG_FILE}"
echo "    Bridge IMAP port and password saved to ${CONFIG_FILE}."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — Register Bridge as a systemd user service
# Running as a user service means Bridge starts at boot without needing root
# and has access to the user's GPG keyring and pass store.
# loginctl enable-linger allows user services to start at boot even without
# an active login session.
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Registering Proton Bridge as a systemd user service..."

mkdir -p ~/.config/systemd/user

cat > ~/.config/systemd/user/proton-bridge.service <<EOF
[Unit]
Description=Proton Mail Bridge
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/proton-bridge --no-window
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable proton-bridge
systemctl --user start proton-bridge
echo "    Bridge service enabled and started."

sudo loginctl enable-linger "$USER"
echo "    Linger enabled for ${USER}."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — Write goimapnotify config
# goimapnotify holds an IMAP IDLE connection open against Bridge's local IMAP
# server. When new mail arrives in PROTON_FOLDER it immediately fires
# ics-sync.py rather than waiting for a polling interval.
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Writing goimapnotify config..."

mkdir -p ~/.config/goimapnotify

cat > ~/.config/goimapnotify/goimapnotify.conf <<EOF
{
  "host": "127.0.0.1",
  "port": ${BRIDGE_IMAP_PORT},
  "tls": false,
  "tlsOptions": {
    "rejectUnauthorized": false
  },
  "username": "${PROTON_EMAIL}",
  "password": "${BRIDGE_IMAP_PASS}",
  "boxes": [
    {
      "mailbox": "${PROTON_FOLDER}",
      "onNewMail": "python3 ${SCRIPT_DIR}/ics-sync.py",
      "onNewMailPost": ""
    }
  ]
}
EOF

echo "    goimapnotify config written."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7 — Register goimapnotify as a systemd user service
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Registering goimapnotify as a systemd user service..."

cat > ~/.config/systemd/user/goimapnotify.service <<EOF
[Unit]
Description=IMAP IDLE watcher for Proton Bridge
After=proton-bridge.service
Requires=proton-bridge.service

[Service]
Type=simple
ExecStart=/usr/local/bin/goimapnotify -conf %h/.config/goimapnotify/goimapnotify.conf
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable goimapnotify
systemctl --user start goimapnotify
echo "    goimapnotify service enabled and started."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8 — Create the log file if it does not exist
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Ensuring log file exists at ${ICS_SYNC_LOG}..."

LOG_DIR=$(dirname "${ICS_SYNC_LOG}")
mkdir -p "$LOG_DIR"
touch "${ICS_SYNC_LOG}"
echo "    Log file ready."

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Done!"
echo ""
echo "  Bridge is running as a systemd user service."
echo "  goimapnotify is watching: ${PROTON_FOLDER}"
echo "  ICS files will be pushed to: ${RADICALE_CALENDAR_URL}"
echo "  Processed email log: ${ICS_SYNC_LOG}"
echo ""
echo "  To check Bridge status:        systemctl --user status proton-bridge"
echo "  To check goimapnotify status:  systemctl --user status goimapnotify"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
