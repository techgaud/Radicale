#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# setup.sh
#
# One-time setup script. Runs in order:
#   1.  Add domain to Cloudflare (create zone)
#   2.  Get assigned nameservers and prompt Namecheap update
#   3.  Poll until zone is active
#   4.  Create short-lived API token for tunnel + DNS operations
#   5.  Authenticate cloudflared and create tunnel
#   6.  Create DNS records for radicale, agendav, and ingest subdomains
#   7.  Write config files: config/config, cloudflared-config/config.yml,
#       agendav-config/settings.php, docker-compose.yml
#   8.  Create Radicale user with bcrypt password
#   9.  Revoke the short-lived API token
#   10. Start the Docker stack
#
# Idempotent: each step checks before acting. Safe to re-run after a failure.
# Will not overwrite docker-compose.yml or cloudflared-config/config.yml if
# the stack is already running — pass --force to override this protection.
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# PARSE FLAGS
# ─────────────────────────────────────────────────────────────────────────────
FORCE=false
CONFIG_FILE="config.env"

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    *.env)   CONFIG_FILE="$arg" ;;
    *)       echo "Usage: $0 [config.env] [--force]"; exit 1 ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────────────
# LOAD CONFIG
# ─────────────────────────────────────────────────────────────────────────────
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found: $CONFIG_FILE"
  echo "Usage: ./setup.sh [path/to/config.env] [--force]"
  exit 1
fi

echo "==> Loading config from ${CONFIG_FILE}..."
source "$CONFIG_FILE"

required_vars=(
  CF_EMAIL CF_GLOBAL_KEY CF_ZONE_ID CF_ACCOUNT_ID
  DOMAIN SUBDOMAIN AGENDAV_SUBDOMAIN INGEST_SUBDOMAIN TUNNEL_NAME
  RADICALE_USER RADICALE_PASS
  TIMEZONE
  INGEST_TOKEN RADICALE_INTERNAL_URL INGEST_PORT
)
missing=0
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} is not set in ${CONFIG_FILE}"
    missing=1
  fi
done
[[ $missing -eq 1 ]] && exit 1

RADICALE_FQDN="${SUBDOMAIN}.${DOMAIN}"
AGENDAV_FQDN="${AGENDAV_SUBDOMAIN}.${DOMAIN}"
INGEST_FQDN="${INGEST_SUBDOMAIN}.${DOMAIN}"

# Token expiry — 1 hour from now
EXPIRES=$(date -u -d "+1 hour" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
          date -u -v+1H +"%Y-%m-%dT%H:%M:%SZ")

# ─────────────────────────────────────────────────────────────────────────────
# OVERWRITE PROTECTION
# If docker-compose.yml exists and the stack is running, refuse to overwrite
# generated files unless --force is passed.
# ─────────────────────────────────────────────────────────────────────────────
STACK_RUNNING=false
if [[ -f "docker-compose.yml" ]] && docker compose ps --quiet 2>/dev/null | grep -q .; then
  STACK_RUNNING=true
fi

if [[ "$STACK_RUNNING" == "true" && "$FORCE" == "false" ]]; then
  echo ""
  echo "WARNING: Docker stack is already running and generated config files exist."
  echo "         Skipping file generation to avoid overwriting your live config."
  echo "         Pass --force to regenerate all files and restart the stack."
  echo ""
  echo "         Safe to re-run setup.sh --force if you have changed config.env"
  echo "         values and want to regenerate everything."
  echo ""
  echo "         Continuing with DNS and auth steps only..."
  SKIP_FILE_GEN=true
else
  SKIP_FILE_GEN=false
fi

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────
cf_global() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -sf -X "$method" "https://api.cloudflare.com/client/v4${endpoint}" \
      -H "X-Auth-Email: ${CF_EMAIL}" \
      -H "X-Auth-Key: ${CF_GLOBAL_KEY}" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -sf -X "$method" "https://api.cloudflare.com/client/v4${endpoint}" \
      -H "X-Auth-Email: ${CF_EMAIL}" \
      -H "X-Auth-Key: ${CF_GLOBAL_KEY}"
  fi
}

cf_token() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -sf -X "$method" "https://api.cloudflare.com/client/v4${endpoint}" \
      -H "Authorization: Bearer ${API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -sf -X "$method" "https://api.cloudflare.com/client/v4${endpoint}" \
      -H "Authorization: Bearer ${API_TOKEN}"
  fi
}

ensure_cname() {
  # Creates a proxied CNAME pointing at the tunnel if it doesn't already exist.
  # Args: subdomain fqdn tunnel_id
  local sub="$1"
  local fqdn="$2"
  local tunnel_id="$3"

  local existing
  existing=$(cf_token GET "/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${fqdn}" \
    | jq -r '.result[0].id // empty')

  if [[ -n "$existing" ]]; then
    echo "    CNAME for ${fqdn} already exists (${existing})."
  else
    local response
    response=$(cf_token POST "/zones/${CF_ZONE_ID}/dns_records" "{
      \"type\": \"CNAME\",
      \"name\": \"${sub}\",
      \"content\": \"${tunnel_id}.cfargotunnel.com\",
      \"ttl\": 60,
      \"proxied\": true
    }")
    local success
    success=$(echo "$response" | jq -r '.success')
    if [[ "$success" != "true" ]]; then
      echo "ERROR: Failed to create DNS record for ${fqdn}."
      echo "$response" | jq '.errors'
      exit 1
    fi
    echo "    Created: ${fqdn} -> ${tunnel_id}.cfargotunnel.com"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: ADD DOMAIN TO CLOUDFLARE
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 1: Add ${DOMAIN} to Cloudflare..."

EXISTING_ZONE=$(cf_global GET "/zones?name=${DOMAIN}" | jq -r '.result[0].id // empty')

if [[ -n "$EXISTING_ZONE" ]]; then
  ZONE_ID="$EXISTING_ZONE"
  echo "    Zone already exists. Zone ID: ${ZONE_ID}"
else
  ZONE_RESPONSE=$(cf_global POST "/zones" "{
    \"name\": \"${DOMAIN}\",
    \"jump_start\": false
  }")
  ZONE_ID=$(echo "$ZONE_RESPONSE" | jq -r '.result.id')
  if [[ -z "$ZONE_ID" || "$ZONE_ID" == "null" ]]; then
    echo "ERROR: Failed to create Cloudflare zone."
    echo "$ZONE_RESPONSE" | jq '.errors'
    exit 1
  fi
  echo "    Zone created. Zone ID: ${ZONE_ID}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: PROMPT NAMECHEAP NAMESERVER UPDATE
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 2: Retrieve Cloudflare nameservers..."

ZONE_INFO=$(cf_global GET "/zones/${ZONE_ID}")
NS1=$(echo "$ZONE_INFO" | jq -r '.result.name_servers[0]')
NS2=$(echo "$ZONE_INFO" | jq -r '.result.name_servers[1]')

if [[ -z "$NS1" || "$NS1" == "null" ]]; then
  echo "ERROR: Could not retrieve nameservers from Cloudflare."
  exit 1
fi

ZONE_STATUS=$(echo "$ZONE_INFO" | jq -r '.result.status')

if [[ "$ZONE_STATUS" == "active" ]]; then
  echo "    Zone is already active, skipping nameserver prompt."
else
  NC_URL="https://ap.www.namecheap.com/domains/domaincontrolpanel/${DOMAIN}/domain"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  MANUAL STEP REQUIRED: Update nameservers in Namecheap"
  echo ""
  echo "  1. Open: ${NC_URL}"
  echo ""
  echo "  2. Under 'Nameservers', select 'Custom DNS' from the dropdown"
  echo ""
  echo "  3. Enter these two nameservers exactly as shown:"
  echo ""
  echo "       Nameserver 1:  ${NS1}"
  echo "       Nameserver 2:  ${NS2}"
  echo ""
  echo "  4. Click the green checkmark to save"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  read -rp "Press Enter once you have saved the nameservers in Namecheap..."
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: WAIT FOR ZONE TO BECOME ACTIVE
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$ZONE_STATUS" != "active" ]]; then
  echo ""
  echo "==> Step 3: Waiting for zone to become active..."
  echo "    Checking every 30 seconds. This can take minutes to hours."

  ATTEMPTS=0
  MAX_ATTEMPTS=360
  while true; do
    if [[ $ATTEMPTS -ge $MAX_ATTEMPTS ]]; then
      echo ""
      echo "ERROR: Zone did not become active after 3 hours."
      exit 1
    fi
    ZONE_STATUS=$(cf_global GET "/zones/${ZONE_ID}" | jq -r '.result.status')
    if [[ "$ZONE_STATUS" == "active" ]]; then
      echo ""
      echo "    Zone is active!"
      break
    fi
    ELAPSED=$(( ATTEMPTS * 30 ))
    printf "\r    Status: %-10s | Elapsed: %ds" "$ZONE_STATUS" "$ELAPSED"
    sleep 30
    ATTEMPTS=$(( ATTEMPTS + 1 ))
  done
else
  echo ""
  echo "==> Step 3: Zone already active, skipping."
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: CREATE SHORT-LIVED API TOKEN
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 4: Create short-lived API token (expires in 1 hour)..."

PERM_GROUPS=$(cf_global GET "/user/tokens/permission_groups")
TUNNEL_PERM_ID=$(echo "$PERM_GROUPS" | jq -r '.result[] | select(.name == "Cloudflare Tunnel Write") | .id')
DNS_PERM_ID=$(echo "$PERM_GROUPS" | jq -r '.result[] | select(.name == "DNS Write") | .id')

if [[ -z "$TUNNEL_PERM_ID" || -z "$DNS_PERM_ID" ]]; then
  echo "ERROR: Could not retrieve permission group IDs."
  exit 1
fi

TOKEN_RESPONSE=$(cf_global POST "/user/tokens" "{
  \"name\": \"radicale-setup-$(date +%s)\",
  \"policies\": [{
    \"effect\": \"allow\",
    \"resources\": {
      \"com.cloudflare.api.account.*\": \"*\",
      \"com.cloudflare.api.account.zone.${ZONE_ID}\": \"*\"
    },
    \"permission_groups\": [
      {\"id\": \"${TUNNEL_PERM_ID}\"},
      {\"id\": \"${DNS_PERM_ID}\"}
    ]
  }],
  \"expires_on\": \"${EXPIRES}\"
}")

API_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.result.value')
API_TOKEN_ID=$(echo "$TOKEN_RESPONSE" | jq -r '.result.id')

if [[ "$API_TOKEN" == "null" || -z "$API_TOKEN" ]]; then
  echo "ERROR: Failed to create API token."
  echo "$TOKEN_RESPONSE" | jq '.errors'
  exit 1
fi
export CLOUDFLARE_API_TOKEN="${API_TOKEN}"
echo "    Token created (ID: ${API_TOKEN_ID})"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: CREATE CLOUDFLARE TUNNEL
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 5: Create Cloudflare Tunnel..."

if [[ -f ~/.cloudflared/cert.pem ]]; then
  echo "    cert.pem already exists, skipping login."
else
  cloudflared tunnel login
fi

EXISTING_TUNNEL=$(cloudflared tunnel list --output json 2>/dev/null | \
  jq -r ".[] | select(.name == \"${TUNNEL_NAME}\") | .id" || true)

if [[ -n "$EXISTING_TUNNEL" ]]; then
  TUNNEL_ID="$EXISTING_TUNNEL"
  echo "    Tunnel already exists. ID: ${TUNNEL_ID}"
else
  cloudflared tunnel create "${TUNNEL_NAME}"
  TUNNEL_ID=$(cloudflared tunnel list --output json | \
    jq -r ".[] | select(.name == \"${TUNNEL_NAME}\") | .id")
  if [[ -z "$TUNNEL_ID" ]]; then
    echo "ERROR: Tunnel was not created successfully."
    exit 1
  fi
  echo "    Tunnel created. ID: ${TUNNEL_ID}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: CREATE DNS RECORDS
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 6: Create DNS CNAME records..."

ensure_cname "$SUBDOMAIN"         "$RADICALE_FQDN" "$TUNNEL_ID"
ensure_cname "$AGENDAV_SUBDOMAIN" "$AGENDAV_FQDN"  "$TUNNEL_ID"
ensure_cname "$INGEST_SUBDOMAIN"  "$INGEST_FQDN"   "$TUNNEL_ID"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7: WRITE CONFIG FILES
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 7: Write config files..."

if [[ "$SKIP_FILE_GEN" == "true" ]]; then
  echo "    Skipped (stack is running — use --force to regenerate)."
else
  mkdir -p config data cloudflared-config/creds agendav-db

  # ── Radicale server config ──────────────────────────────────────────────────
  cat > config/config <<EOF
[server]
hosts = 0.0.0.0:5232

[auth]
type = htpasswd
htpasswd_filename = /config/users
htpasswd_encryption = bcrypt

[storage]
filesystem_folder = /data/collections
EOF
  echo "    Written: config/config"

  # ── Cloudflare Tunnel ingress config ───────────────────────────────────────
  # Copy tunnel credentials if not already present
  if [[ ! -f "cloudflared-config/creds/${TUNNEL_ID}.json" ]]; then
    cp ~/.cloudflared/${TUNNEL_ID}.json cloudflared-config/creds/
    chmod 644 "cloudflared-config/creds/${TUNNEL_ID}.json"
  fi

  cat > cloudflared-config/config.yml <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/creds/${TUNNEL_ID}.json

ingress:
  - hostname: ${RADICALE_FQDN}
    service: http://radicale:5232
  - hostname: ${AGENDAV_FQDN}
    service: http://agendav:8080
  - hostname: ${INGEST_FQDN}
    service: http://ingest:8000
  - service: http_status:404
EOF
  echo "    Written: cloudflared-config/config.yml"

  # ── AgenDAV settings.php (generated from settings.php.example) ─────────────
  if [[ ! -f "agendav-config/settings.php.example" ]]; then
    echo "ERROR: agendav-config/settings.php.example not found."
    exit 1
  fi
  sed \
    -e "s|%%DOMAIN%%|${DOMAIN}|g" \
    -e "s|%%RADICALE_SUBDOMAIN%%|${SUBDOMAIN}|g" \
    -e "s|%%TIMEZONE%%|${TIMEZONE}|g" \
    agendav-config/settings.php.example > agendav-config/settings.php
  echo "    Written: agendav-config/settings.php"

  # ── docker-compose.yml ─────────────────────────────────────────────────────
  cat > docker-compose.yml <<EOF
services:
  radicale:
    image: tomsquest/docker-radicale
    container_name: radicale
    expose:
      - "5232"
    volumes:
      - ./data:/data
      - ./config:/config
    restart: unless-stopped

  agendav:
    image: ghcr.io/nagimov/agendav-docker:latest
    container_name: agendav
    expose:
      - "8080"
    environment:
      - AGENDAV_SERVER_NAME=${AGENDAV_FQDN}
      - AGENDAV_TITLE=Calendar
      - AGENDAV_FOOTER=${DOMAIN}
      - AGENDAV_CALDAV_SERVER=http://radicale:5232
      - AGENDAV_CALDAV_PUBLIC_URL=https://${RADICALE_FQDN}
      - AGENDAV_TIMEZONE=${TIMEZONE}
      - AGENDAV_LANG=en
      - AGENDAV_LOG_DIR=/tmp/
    entrypoint: ["/bin/bash", "/var/www/agendav/web/config/entrypoint.sh"]
    volumes:
      - ./agendav-config:/var/www/agendav/web/config
      - ./agendav-db:/var/www/agendav/db
    restart: unless-stopped
    depends_on:
      - radicale

  ingest:
    image: python:3.11-slim
    container_name: ingest
    expose:
      - "8000"
    working_dir: /app
    command: python3 ingest.py
    volumes:
      - ./ingest.py:/app/ingest.py:ro
      - ./config.env:/app/config.env:ro
    restart: unless-stopped
    depends_on:
      - radicale

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate run
    volumes:
      - ./cloudflared-config:/etc/cloudflared
    depends_on:
      - radicale
      - agendav
      - ingest
EOF
  echo "    Written: docker-compose.yml"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8: CREATE RADICALE USER
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 8: Create Radicale user..."

if [[ -f "config/users" && "$FORCE" == "false" ]]; then
  echo "    config/users already exists, skipping."
  echo "    (Pass --force to regenerate with the current RADICALE_PASS)"
else
  HASHED=$(docker run --rm python:3-alpine sh -c \
    "pip install bcrypt -q && python3 -c \
    \"import bcrypt; print(bcrypt.hashpw(b'${RADICALE_PASS}', bcrypt.gensalt()).decode())\"")
  echo "${RADICALE_USER}:${HASHED}" > config/users
  echo "    User created: ${RADICALE_USER}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 9: REVOKE SHORT-LIVED TOKEN
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 9: Revoke short-lived API token..."

REVOKE_RESULT=$(cf_global DELETE "/user/tokens/${API_TOKEN_ID}" | jq -r '.success')
if [[ "$REVOKE_RESULT" == "true" ]]; then
  echo "    Token revoked."
else
  echo "WARNING: Token revocation may have failed."
  echo "         Revoke it manually at: https://dash.cloudflare.com/profile/api-tokens"
fi
unset CLOUDFLARE_API_TOKEN

# ─────────────────────────────────────────────────────────────────────────────
# STEP 10: START DOCKER STACK
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 10: Start Docker stack..."

if [[ "$FORCE" == "true" ]]; then
  docker compose up -d --force-recreate
else
  docker compose up -d
fi

# ─────────────────────────────────────────────────────────────────────────────
# DONE
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Setup complete."
echo ""
echo "  Radicale:  https://${RADICALE_FQDN}"
echo "  AgenDAV:   https://${AGENDAV_FQDN}"
echo "  Ingest:    https://${INGEST_FQDN}"
echo "  DAVx5 URL: https://${RADICALE_FQDN}/${RADICALE_USER}/"
echo ""
echo "  Next: run ./cloudflare-setup.sh to deploy the Email Worker"
echo "        and set up Email Routing rules."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
