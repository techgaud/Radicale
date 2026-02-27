#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# remove-bridge.sh
#
# Tears down the Proton Bridge / goimapnotify / ics-sync stack now that
# the Cloudflare Email Routing pipeline has replaced it.
#
# What this script does:
#   1. Stops and disables proton-bridge, goimapnotify, ics-sync, ics-sync.timer
#   2. Removes the systemd unit files
#   3. Reloads systemd user daemon
#   4. Removes goimapnotify binary and config
#   5. Removes Go toolchain (was only needed to build goimapnotify)
#   6. Uninstalls protonmail-bridge via apt
#   7. Removes the pass credential store and GPG keys used by Bridge
#   8. Cleans up Bridge-related vars from config.env
#
# Safe to run: each step checks before acting.
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  remove-bridge.sh                                               ║"
echo "║  Removing Proton Bridge and associated services                 ║"
echo "╚══════════════════════════════════════════════════════════════════╝"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: STOP AND DISABLE SYSTEMD SERVICES
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 1: Stop and disable systemd user services..."

for unit in ics-sync.timer ics-sync.service goimapnotify.service proton-bridge.service; do
  if systemctl --user is-active --quiet "$unit" 2>/dev/null; then
    systemctl --user stop "$unit"
    echo "    Stopped: ${unit}"
  else
    echo "    Already stopped: ${unit}"
  fi

  if systemctl --user is-enabled --quiet "$unit" 2>/dev/null; then
    systemctl --user disable "$unit"
    echo "    Disabled: ${unit}"
  else
    echo "    Already disabled: ${unit}"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: REMOVE UNIT FILES
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 2: Remove systemd unit files..."

UNIT_DIR="${HOME}/.config/systemd/user"
for unit in proton-bridge.service goimapnotify.service ics-sync.service ics-sync.timer; do
  if [[ -f "${UNIT_DIR}/${unit}" ]]; then
    rm "${UNIT_DIR}/${unit}"
    echo "    Removed: ${UNIT_DIR}/${unit}"
  else
    echo "    Not found: ${unit}"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: RELOAD SYSTEMD
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 3: Reload systemd user daemon..."
systemctl --user daemon-reload
echo "    Done."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: REMOVE GOIMAPNOTIFY
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 4: Remove goimapnotify..."

if [[ -f /usr/local/bin/goimapnotify ]]; then
  sudo rm /usr/local/bin/goimapnotify
  echo "    Removed: /usr/local/bin/goimapnotify"
else
  echo "    Not found: /usr/local/bin/goimapnotify"
fi

if [[ -d "${HOME}/.config/goimapnotify" ]]; then
  rm -rf "${HOME}/.config/goimapnotify"
  echo "    Removed: ~/.config/goimapnotify"
else
  echo "    Not found: ~/.config/goimapnotify"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: REMOVE GO TOOLCHAIN
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 5: Remove Go toolchain..."

if [[ -d /usr/local/go ]]; then
  sudo rm -rf /usr/local/go
  echo "    Removed: /usr/local/go"
else
  echo "    Not found: /usr/local/go"
fi

# Remove Go bin from .bashrc / .profile if present
for rcfile in "${HOME}/.bashrc" "${HOME}/.profile"; do
  if [[ -f "$rcfile" ]] && grep -q '/usr/local/go/bin' "$rcfile"; then
    sed -i '/\/usr\/local\/go\/bin/d' "$rcfile"
    echo "    Removed Go PATH entry from ${rcfile}"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: UNINSTALL PROTON BRIDGE
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 6: Uninstall protonmail-bridge via apt..."

if dpkg -l protonmail-bridge &>/dev/null; then
  sudo apt remove -y protonmail-bridge
  sudo apt autoremove -y
  echo "    protonmail-bridge uninstalled."
else
  echo "    protonmail-bridge not found in apt — already removed or installed differently."
fi

# Remove Bridge cache/config directories
for dir in \
  "${HOME}/.cache/protonmail" \
  "${HOME}/.config/protonmail" \
  "${HOME}/.local/share/protonmail"; do
  if [[ -d "$dir" ]]; then
    rm -rf "$dir"
    echo "    Removed: ${dir}"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7: REMOVE PASS STORE AND GPG KEYS
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 7: Remove pass credential store and Bridge GPG keys..."

if [[ -d "${HOME}/.password-store" ]]; then
  rm -rf "${HOME}/.password-store"
  echo "    Removed: ~/.password-store"
else
  echo "    Not found: ~/.password-store"
fi

# Delete the specific GPG keys used by Bridge
# These keygrips are Bridge-specific — documented in project_knowledge.md
BRIDGE_KEYGRIPS=(
  "BEFED5349CA3A93E5DDF61B4F0DE680CF5967788"
  "C2AAA4927A80BEA918357C7CB88C4998480E4F5A"
)

for keygrip in "${BRIDGE_KEYGRIPS[@]}"; do
  # Find the fingerprint associated with this keygrip
  fingerprint=$(gpg --with-keygrip --fingerprint 2>/dev/null \
    | grep -B1 "$keygrip" | grep -E '^[[:space:]]+[A-F0-9]{40}' \
    | tr -d ' ' | head -1 || true)

  if [[ -n "$fingerprint" ]]; then
    gpg --batch --yes --delete-secret-and-public-key "$fingerprint" 2>/dev/null && \
      echo "    Deleted GPG key: ${fingerprint}" || \
      echo "    Could not delete GPG key: ${fingerprint} (may need manual removal)"
  else
    echo "    GPG key not found for keygrip: ${keygrip}"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8: CLEAN UP config.env
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 8: Remove Bridge-related vars from config.env..."

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "    config.env not found — skipping."
else
  tmp_file=$(mktemp)
  grep -v -E '^(PROTON_EMAIL|PROTON_FOLDER|BRIDGE_IMAP_PORT|BRIDGE_IMAP_PASS|GPG_PASSPHRASE)=' \
    "$CONFIG_FILE" > "$tmp_file"
  mv "$tmp_file" "$CONFIG_FILE"
  echo "    Removed: PROTON_EMAIL, PROTON_FOLDER, BRIDGE_IMAP_PORT, BRIDGE_IMAP_PASS, GPG_PASSPHRASE"
fi

# ─────────────────────────────────────────────────────────────────────────────
# DONE
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Bridge removal complete.                                       ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "Verify the ingest pipeline is still healthy:"
echo "  docker logs ingest --tail 20"
echo ""
echo "Then commit the config.env change and any remaining file cleanup:"
echo "  cd /mnt/md0/docker/radicale && ./commit.sh"
