#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# LOAD CONFIG
# ─────────────────────────────────────────────────────────────────────────────
CONFIG_FILE="${1:-config.env}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found: $CONFIG_FILE"
  echo "Usage: ./github-setup.sh [path/to/config.env]"
  exit 1
fi

echo "==> Loading config from ${CONFIG_FILE}..."
source "$CONFIG_FILE"

# Validate required fields
required_vars=(GITHUB_USERNAME GITHUB_TOKEN GITHUB_REPO)
missing=0
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} is not set in ${CONFIG_FILE}"
    missing=1
  fi
done
[[ $missing -eq 1 ]] && exit 1

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Create the GitHub repository via API
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Creating GitHub repository: ${GITHUB_USERNAME}/${GITHUB_REPO}..."

REPO_RESPONSE=$(curl -sf -X POST "https://api.github.com/user/repos" \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  --data "{
    \"name\": \"${GITHUB_REPO}\",
    \"description\": \"Self-hosted Radicale CalDAV/CardDAV server with Cloudflare Tunnel\",
    \"private\": false,
    \"auto_init\": false
  }")

REPO_URL=$(echo "$REPO_RESPONSE" | jq -r '.html_url')
CLONE_URL=$(echo "$REPO_RESPONSE" | jq -r '.clone_url')

if [[ -z "$REPO_URL" || "$REPO_URL" == "null" ]]; then
  # Check if it already exists
  EXISTING=$(curl -sf -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    "https://api.github.com/repos/${GITHUB_USERNAME}/${GITHUB_REPO}")

  if [[ "$EXISTING" == "200" ]]; then
    echo "    Repository already exists, continuing..."
    CLONE_URL="https://github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"
  else
    echo "ERROR: Failed to create GitHub repository."
    echo "$REPO_RESPONSE" | jq '.message'
    exit 1
  fi
else
  echo "    Repository created: ${REPO_URL}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — Initialise git in the project directory
# ─────────────────────────────────────────────────────────────────────────────
# Allow git to work across filesystem mount boundaries (e.g. /mnt/md0/)
export GIT_DISCOVERY_ACROSS_FILESYSTEM=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Initialising git repository..."

if [[ ! -d ".git" ]]; then
  git init
  echo "    Initialised empty git repository."
else
  echo "    Git already initialised, continuing..."
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Configure git identity if not already set
# ─────────────────────────────────────────────────────────────────────────────
if [[ -z "$(git config --global user.email 2>/dev/null || true)" ]]; then
  echo "==> Configuring git identity..."

  # Fetch the primary email from GitHub
  GH_EMAIL=$(curl -sf "https://api.github.com/user/emails" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" | \
    jq -r '.[] | select(.primary == true) | .email')

  GH_NAME=$(curl -sf "https://api.github.com/user" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" | \
    jq -r '.name // .login')

  git config --global user.email "${GH_EMAIL}"
  git config --global user.name "${GH_NAME}"
  echo "    Set git identity to: ${GH_NAME} <${GH_EMAIL}>"
else
  echo "==> git identity: OK ($(git config --global user.email))"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — Stage and commit
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Staging files..."
git add .

# Show what is being committed so there are no surprises
echo "    Files staged for commit:"
git diff --cached --name-only | sed 's/^/      /'

echo "==> Creating initial commit..."
git commit -m "Initial commit"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — Set remote and push
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Setting remote origin..."

# Embed the token in the remote URL for auth — avoids interactive prompts
AUTH_CLONE_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"

if git remote get-url origin &>/dev/null; then
  git remote set-url origin "${AUTH_CLONE_URL}"
else
  git remote add origin "${AUTH_CLONE_URL}"
fi

echo "==> Pushing to GitHub..."
git push -u origin main 2>/dev/null || git push -u origin master

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7 — Revoke the GitHub token
# GitHub PATs cannot be revoked via API — remind the user to do it manually.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Cleaning up..."

# Remove the token from the remote URL now that push is done
git remote set-url origin "https://github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Done!"
echo ""
echo "  Repository: https://github.com/${GITHUB_USERNAME}/${GITHUB_REPO}"
echo ""
echo "  ACTION REQUIRED: Revoke your GitHub Personal Access Token"
echo "  now that setup is complete."
echo "  https://github.com/settings/tokens"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
