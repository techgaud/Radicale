#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# LOAD CONFIG
# ─────────────────────────────────────────────────────────────────────────────
CONFIG_FILE="${1:-config.env}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found: $CONFIG_FILE"
  echo "Usage: ./setup.sh [path/to/config.env]"
  exit 1
fi

echo "==> Loading config from ${CONFIG_FILE}..."
source "$CONFIG_FILE"

# Validate all required fields are present
required_vars=(
  CF_EMAIL CF_GLOBAL_KEY
  DOMAIN SUBDOMAIN TUNNEL_NAME
  RADICALE_USER RADICALE_PASS
)
missing=0
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} is not set in ${CONFIG_FILE}"
    missing=1
  fi
done
[[ $missing -eq 1 ]] && exit 1

FQDN="${SUBDOMAIN}.${DOMAIN}"

# Token expiry — 1 hour from now
EXPIRES=$(date -u -d "+1 hour" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
          date -u -v+1H +"%Y-%m-%dT%H:%M:%SZ")

# ─────────────────────────────────────────────────────────────────────────────
# HELPER: Cloudflare API call using Global Key
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

# ─────────────────────────────────────────────────────────────────────────────
# HELPER: Cloudflare API call using scoped Bearer token
# ─────────────────────────────────────────────────────────────────────────────
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

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Add domain to Cloudflare (create zone)
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Adding ${DOMAIN} to Cloudflare..."

# Check if zone already exists first
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
# STEP 3 — Get the nameservers Cloudflare assigned to this zone
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Retrieving Cloudflare nameservers for ${DOMAIN}..."
ZONE_INFO=$(cf_global GET "/zones/${ZONE_ID}")
NS1=$(echo "$ZONE_INFO" | jq -r '.result.name_servers[0]')
NS2=$(echo "$ZONE_INFO" | jq -r '.result.name_servers[1]')

if [[ -z "$NS1" || "$NS1" == "null" ]]; then
  echo "ERROR: Could not retrieve nameservers from Cloudflare."
  exit 1
fi
echo "    Nameserver 1: ${NS1}"
echo "    Nameserver 2: ${NS2}"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Update Namecheap nameservers manually
# Cloudflare has assigned two nameservers to your zone. You need to log in
# to Namecheap and point your domain at those nameservers. This script will
# open the correct Namecheap page and tell you exactly what to enter.
# ─────────────────────────────────────────────────────────────────────────────
NC_URL="https://ap.www.namecheap.com/domains/domaincontrolpanel/${DOMAIN}/domain"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  MANUAL STEP REQUIRED: Update nameservers in Namecheap"
echo ""
echo "  1. Open the Namecheap domain management page:"
echo ""
printf "     \e]8;;%s\e\\%s\e]8;;\e\\\n" "$NC_URL" "     Open Namecheap domain management page"
echo ""
echo "     $NC_URL"
echo ""
echo "  2. Under 'Nameservers', select 'Custom DNS' from the dropdown"
echo ""
echo "  3. Enter the following two nameservers exactly as shown:"
echo ""
echo "       Nameserver 1:  ${NS1}"
echo "       Nameserver 2:  ${NS2}"
echo ""
echo "  4. Click the green checkmark to save"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -rp "Press Enter once you have saved the nameservers in Namecheap..."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — Poll Cloudflare until zone becomes active
# Nameserver propagation can take anywhere from minutes to hours.
# We poll every 30 seconds and print a status update each time.
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Waiting for Cloudflare zone to become active..."
echo "    This may take anywhere from a few minutes to a few hours."
echo "    Checking every 30 seconds..."

ZONE_ACTIVE=false
ATTEMPTS=0
MAX_ATTEMPTS=360  # 360 x 30s = 3 hours max before giving up

while [[ "$ZONE_ACTIVE" == "false" ]]; do
  if [[ $ATTEMPTS -ge $MAX_ATTEMPTS ]]; then
    echo ""
    echo "ERROR: Zone did not become active after 3 hours."
    echo "       Check your Cloudflare dashboard and Namecheap nameserver settings."
    exit 1
  fi

  ZONE_STATUS=$(cf_global GET "/zones/${ZONE_ID}" | jq -r '.result.status')

  if [[ "$ZONE_STATUS" == "active" ]]; then
    ZONE_ACTIVE=true
    echo ""
    echo "    Zone is active!"
  else
    ELAPSED=$(( ATTEMPTS * 30 ))
    printf "\r    Status: %-10s | Elapsed: %ds" "$ZONE_STATUS" "$ELAPSED"
    sleep 30
    ATTEMPTS=$(( ATTEMPTS + 1 ))
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — Create short-lived Cloudflare API token
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Looking up Cloudflare permission group IDs..."
PERM_GROUPS=$(cf_global GET "/user/tokens/permission_groups")
TUNNEL_PERM_ID=$(echo "$PERM_GROUPS" | jq -r '.result[] | select(.name == "Cloudflare Tunnel Write") | .id')
DNS_PERM_ID=$(echo "$PERM_GROUPS" | jq -r '.result[] | select(.name == "DNS Write") | .id')

if [[ -z "$TUNNEL_PERM_ID" || -z "$DNS_PERM_ID" ]]; then
  echo "ERROR: Could not retrieve permission group IDs."
  exit 1
fi
echo "    Tunnel perm: ${TUNNEL_PERM_ID}"
echo "    DNS perm:    ${DNS_PERM_ID}"

echo "==> Creating short-lived API token (expires in 1 hour)..."
TOKEN_RESPONSE=$(cf_global POST "/user/tokens" "{
  \"name\": \"cloudflared-setup-$(date +%s)\",
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
echo "    Token created. ID: ${API_TOKEN_ID}"

export CLOUDFLARE_API_TOKEN="${API_TOKEN}"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7 — Authenticate cloudflared and create tunnel
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Authenticating cloudflared..."
if [[ -f ~/.cloudflared/cert.pem ]]; then
  echo "    cert.pem already exists, skipping login."
else
  cloudflared tunnel login
fi

echo "==> Creating tunnel: ${TUNNEL_NAME}..."
EXISTING_TUNNEL=$(cloudflared tunnel list --output json 2>/dev/null | \
  jq -r ".[] | select(.name == \"${TUNNEL_NAME}\") | .id" || true)

if [[ -n "$EXISTING_TUNNEL" ]]; then
  TUNNEL_ID="$EXISTING_TUNNEL"
  echo "    Tunnel already exists. Tunnel ID: ${TUNNEL_ID}"
else
  cloudflared tunnel create "${TUNNEL_NAME}"
  TUNNEL_ID=$(cloudflared tunnel list --output json | \
    jq -r ".[] | select(.name == \"${TUNNEL_NAME}\") | .id")
  if [[ -z "$TUNNEL_ID" ]]; then
    echo "ERROR: Tunnel was not created successfully."
    exit 1
  fi
  echo "    Tunnel ID: ${TUNNEL_ID}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8 — Create DNS record via Cloudflare API directly
# We do this instead of 'cloudflared tunnel route dns' so we can set the TTL.
# Note: When proxied=true, Cloudflare manages the external TTL automatically
# (this is required for tunnels). The 60s TTL applies when proxying is off,
# and ensures fast updates if you ever reconfigure things.
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Creating DNS CNAME record for ${FQDN} (TTL: 60s)..."
EXISTING_DNS=$(cf_token GET "/zones/${ZONE_ID}/dns_records?type=CNAME&name=${SUBDOMAIN}" | \
  jq -r '.result[0].id // empty')

if [[ -n "$EXISTING_DNS" ]]; then
  echo "    DNS record already exists, skipping."
else
  DNS_RESPONSE=$(cf_token POST "/zones/${ZONE_ID}/dns_records" "{
    \"type\": \"CNAME\",
    \"name\": \"${SUBDOMAIN}\",
    \"content\": \"${TUNNEL_ID}.cfargotunnel.com\",
    \"ttl\": 60,
    \"proxied\": true
  }")
  DNS_SUCCESS=$(echo "$DNS_RESPONSE" | jq -r '.success')
  if [[ "$DNS_SUCCESS" != "true" ]]; then
    echo "ERROR: Failed to create DNS record."
    echo "$DNS_RESPONSE" | jq '.errors'
    exit 1
  fi
  echo "    DNS record created."
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 9 — Write all config files
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Writing config files..."
mkdir -p config data cloudflared-config/creds

# Radicale server config
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

# cloudflared ingress config
cat > cloudflared-config/config.yml <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/creds/${TUNNEL_ID}.json

ingress:
  - hostname: ${FQDN}
    service: http://radicale:5232
  - service: http_status:404
EOF

# Copy tunnel credentials so the cloudflared container can use them.
# Only copy if not already present — avoids overwriting on re-runs.
# chmod 644 ensures the container process can read the file.
if [[ ! -f "cloudflared-config/creds/${TUNNEL_ID}.json" ]]; then
  cp ~/.cloudflared/${TUNNEL_ID}.json cloudflared-config/creds/
  chmod 644 "cloudflared-config/creds/${TUNNEL_ID}.json"
fi

# Docker Compose
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

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate run
    volumes:
      - ./cloudflared-config:/etc/cloudflared
    depends_on:
      - radicale
EOF

# ─────────────────────────────────────────────────────────────────────────────
# STEP 10 — Create Radicale user with bcrypt password
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Creating Radicale user..."
HASHED=$(docker run --rm python:3-alpine sh -c \
  "pip install bcrypt -q && python3 -c \
  \"import bcrypt; print(bcrypt.hashpw(b'${RADICALE_PASS}', bcrypt.gensalt()).decode())\"")
echo "${RADICALE_USER}:${HASHED}" > config/users
echo "    User created: ${RADICALE_USER}"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 11 — Revoke the short-lived API token
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Revoking short-lived API token..."
REVOKE_RESULT=$(cf_global DELETE "/user/tokens/${API_TOKEN_ID}" | jq -r '.success')
if [[ "$REVOKE_RESULT" == "true" ]]; then
  echo "    Token revoked successfully."
else
  echo "WARNING: Token revocation may have failed."
  echo "         Revoke it manually at: https://dash.cloudflare.com/profile/api-tokens"
fi
unset CLOUDFLARE_API_TOKEN

# ─────────────────────────────────────────────────────────────────────────────
# STEP 12 — Start the stack
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Starting Docker stack..."
docker compose up -d

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Done!"
echo ""
echo "  Radicale URL:  https://${FQDN}"
echo "  Username:      ${RADICALE_USER}"
echo "  DAVx5 URL:     https://${FQDN}/${RADICALE_USER}/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
