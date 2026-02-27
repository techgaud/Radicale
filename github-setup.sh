#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# github-setup.sh
#
# One-time setup. Creates the GitHub repository, generates an SSH deploy key,
# registers it on the repo, and configures git to use it for all future pushes.
#
# What it does:
#   1. Creates the GitHub repository using GITHUB_TOKEN (classic PAT)
#   2. Initialises git and configures identity if needed
#   3. Generates an ed25519 SSH deploy key at ~/.ssh/radicale_deploy
#   4. Registers the public key as a deploy key on the repo via the API
#   5. Writes a Host alias to ~/.ssh/config so git uses the right key
#   6. Stages and creates the initial commit
#   7. Sets remote to SSH and pushes
#   8. Clears GITHUB_TOKEN from config.env (no longer needed)
#
# Prerequisites:
#   - config.env populated with: GITHUB_USERNAME, GITHUB_TOKEN, GITHUB_REPO
#   - GITHUB_TOKEN is a classic PAT with the 'repo' scope
#
# After this script runs:
#   - GITHUB_TOKEN is cleared from config.env
#   - commit.sh uses SSH via the deploy key for all future pushes
#   - The classic PAT can be revoked manually (link shown at the end)
# ─────────────────────────────────────────────────────────────────────────────

export GIT_DISCOVERY_ACROSS_FILESYSTEM=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
DEPLOY_KEY_PATH="${HOME}/.ssh/radicale_deploy"
SSH_CONFIG="${HOME}/.ssh/config"
SSH_HOST_ALIAS="github-radicale"

# ─────────────────────────────────────────────────────────────────────────────
# LOAD CONFIG
# ─────────────────────────────────────────────────────────────────────────────
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config.env not found at ${CONFIG_FILE}"
  exit 1
fi

echo "==> Loading config from ${CONFIG_FILE}..."
source "$CONFIG_FILE"

required_vars=(GITHUB_USERNAME GITHUB_TOKEN GITHUB_REPO)
missing=0
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} is not set in ${CONFIG_FILE}"
    missing=1
  fi
done
[[ $missing -eq 1 ]] && exit 1

gh_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -sf -X "$method" "https://api.github.com${endpoint}" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -sf -X "$method" "https://api.github.com${endpoint}" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: CREATE GITHUB REPOSITORY
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 1: Create GitHub repository ${GITHUB_USERNAME}/${GITHUB_REPO}..."

EXISTING=$(curl -sf -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  "https://api.github.com/repos/${GITHUB_USERNAME}/${GITHUB_REPO}")

if [[ "$EXISTING" == "200" ]]; then
  echo "    Repository already exists, continuing."
else
  REPO_RESPONSE=$(gh_api POST "/user/repos" "{
    \"name\": \"${GITHUB_REPO}\",
    \"description\": \"Self-hosted Radicale CalDAV server with Cloudflare Tunnel\",
    \"private\": false,
    \"auto_init\": false
  }")
  REPO_URL=$(echo "$REPO_RESPONSE" | jq -r '.html_url')
  if [[ -z "$REPO_URL" || "$REPO_URL" == "null" ]]; then
    echo "ERROR: Failed to create repository."
    echo "$REPO_RESPONSE" | jq '.message'
    exit 1
  fi
  echo "    Repository created: ${REPO_URL}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: INITIALISE GIT + CONFIGURE IDENTITY
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 2: Initialise git repository..."

cd "$SCRIPT_DIR"

if [[ ! -d ".git" ]]; then
  git init
  echo "    Initialised empty git repository."
else
  echo "    Already initialised."
fi

if [[ -z "$(git config --global user.email 2>/dev/null || true)" ]]; then
  echo "==> Configuring git identity..."
  GH_EMAIL=$(gh_api GET "/user/emails" | jq -r '.[] | select(.primary == true) | .email')
  GH_NAME=$(gh_api GET "/user" | jq -r '.name // .login')
  git config --global user.email "${GH_EMAIL}"
  git config --global user.name "${GH_NAME}"
  echo "    Set: ${GH_NAME} <${GH_EMAIL}>"
else
  echo "    Identity already set: $(git config --global user.email)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: GENERATE SSH DEPLOY KEY
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 3: Generate SSH deploy key..."

mkdir -p ~/.ssh
chmod 700 ~/.ssh

if [[ -f "$DEPLOY_KEY_PATH" ]]; then
  echo "    Deploy key already exists at ${DEPLOY_KEY_PATH}, skipping generation."
else
  ssh-keygen -t ed25519 -f "$DEPLOY_KEY_PATH" -N "" \
    -C "radicale-deploy-$(date +%Y%m%d)"
  chmod 600 "${DEPLOY_KEY_PATH}"
  chmod 644 "${DEPLOY_KEY_PATH}.pub"
  echo "    Key generated: ${DEPLOY_KEY_PATH}"
fi

PUBLIC_KEY=$(cat "${DEPLOY_KEY_PATH}.pub")

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: REGISTER DEPLOY KEY ON GITHUB REPO
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 4: Register deploy key on ${GITHUB_USERNAME}/${GITHUB_REPO}..."

# Check if a deploy key with this title already exists
EXISTING_KEY=$(gh_api GET "/repos/${GITHUB_USERNAME}/${GITHUB_REPO}/keys" \
  | jq -r '.[] | select(.title == "radicale-deploy") | .id // empty' | head -1)

if [[ -n "$EXISTING_KEY" ]]; then
  echo "    Deploy key already registered (ID: ${EXISTING_KEY}), skipping."
else
  KEY_RESPONSE=$(gh_api POST "/repos/${GITHUB_USERNAME}/${GITHUB_REPO}/keys" "{
    \"title\": \"radicale-deploy\",
    \"key\": \"${PUBLIC_KEY}\",
    \"read_only\": false
  }")
  KEY_ID=$(echo "$KEY_RESPONSE" | jq -r '.id // empty')
  if [[ -z "$KEY_ID" ]]; then
    echo "ERROR: Failed to register deploy key."
    echo "$KEY_RESPONSE" | jq '.message'
    exit 1
  fi
  echo "    Deploy key registered (ID: ${KEY_ID})."
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: WRITE SSH CONFIG HOST ALIAS
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 5: Configure SSH host alias..."

touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

if grep -q "Host ${SSH_HOST_ALIAS}" "$SSH_CONFIG" 2>/dev/null; then
  echo "    SSH host alias '${SSH_HOST_ALIAS}' already present in ${SSH_CONFIG}."
else
  cat >> "$SSH_CONFIG" <<EOF

# Added by radicale github-setup.sh
Host ${SSH_HOST_ALIAS}
  HostName github.com
  User git
  IdentityFile ${DEPLOY_KEY_PATH}
  IdentitiesOnly yes
EOF
  echo "    Host alias '${SSH_HOST_ALIAS}' written to ${SSH_CONFIG}."
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: STAGE AND COMMIT
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 6: Stage and create initial commit..."

git add .

echo "    Files staged:"
git diff --cached --name-only | sed 's/^/      /'

if git diff --cached --quiet; then
  echo "    Nothing to commit — working tree already clean."
else
  git commit -m "Initial commit"
  echo "    Committed."
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7: SET SSH REMOTE AND PUSH
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 7: Set SSH remote and push..."

SSH_REMOTE="git@${SSH_HOST_ALIAS}:${GITHUB_USERNAME}/${GITHUB_REPO}.git"

if git remote get-url origin &>/dev/null; then
  git remote set-url origin "$SSH_REMOTE"
else
  git remote add origin "$SSH_REMOTE"
fi

echo "    Remote: ${SSH_REMOTE}"

# Give GitHub a moment to register the deploy key before connecting
sleep 2

# Add github.com to known_hosts if not already there
ssh-keyscan -H github.com >> ~/.ssh/known_hosts 2>/dev/null

echo "    Pushing..."
git push -u origin main 2>/dev/null || git push -u origin master
echo "    Pushed."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8: CLEAR GITHUB_TOKEN FROM CONFIG.ENV
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 8: Clear GITHUB_TOKEN from config.env..."

sed -i 's|^GITHUB_TOKEN=.*|GITHUB_TOKEN=""|' "$CONFIG_FILE"
echo "    GITHUB_TOKEN cleared."
echo "    All future pushes use the SSH deploy key — the classic PAT is no longer needed."

# ─────────────────────────────────────────────────────────────────────────────
# DONE
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Done!"
echo ""
echo "  Repository: https://github.com/${GITHUB_USERNAME}/${GITHUB_REPO}"
echo "  Deploy key: ${DEPLOY_KEY_PATH}"
echo ""
echo "  ACTION REQUIRED: Revoke your classic PAT — it is no longer needed."
echo "  https://github.com/settings/tokens"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
