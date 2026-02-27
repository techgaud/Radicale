#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# cloudflare-setup.sh
#
# One-time setup for Cloudflare Email Routing + Email Worker.
# Run this once before provision-calendar.sh or any end-to-end testing.
#
# What it does:
#   1. Enables Email Routing on the zone (if not already enabled)
#   2. Creates the inbound.natecalvert.org DNS CNAME for the tunnel
#   3. Deploys the Email Worker via Wrangler
#   4. Sets Worker secrets (INGEST_URL, INGEST_TOKEN) via Wrangler
#   5. Creates Email Routing rules for the three initial addresses
#
# Prerequisites:
#   - Node.js and npm installed (for Wrangler)
#   - Wrangler installed: npm install -g wrangler
#   - config.env populated with:
#       CF_API_TOKEN, CF_ZONE_ID, CF_ACCOUNT_ID, CF_EMAIL, CF_GLOBAL_KEY,
#       DOMAIN, INGEST_TOKEN, RADICALE_USER, RADICALE_PASS, TUNNEL_NAME
#   - worker/email-worker.js and worker/wrangler.toml present
#
# Idempotent: safe to re-run. Existing rules and secrets are skipped or updated.
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
WORKER_DIR="${SCRIPT_DIR}/worker"

# ─────────────────────────────────────────────────────────────────────────────
# LOAD CONFIG
# ─────────────────────────────────────────────────────────────────────────────
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config.env not found at ${CONFIG_FILE}"
  exit 1
fi
source "$CONFIG_FILE"

required_vars=(CF_API_TOKEN CF_ZONE_ID CF_ACCOUNT_ID CF_EMAIL CF_GLOBAL_KEY \
               DOMAIN INGEST_TOKEN RADICALE_USER RADICALE_PASS TUNNEL_NAME)
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} is not set in config.env"
    exit 1
  fi
done

INGEST_URL="https://inbound.${DOMAIN}/ingest"

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

# Cloudflare API using Bearer token (Email Routing + Workers APIs)
cf_bearer() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  if [[ -n "$data" ]]; then
    curl -sf -X "$method" "https://api.cloudflare.com/client/v4${endpoint}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -sf -X "$method" "https://api.cloudflare.com/client/v4${endpoint}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}"
  fi
}

# Cloudflare API using Global Key (DNS records — same as create-subdomain.sh)
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

check_success() {
  local response="$1"
  local label="$2"
  local success
  success=$(echo "$response" | jq -r '.success // false')
  if [[ "$success" != "true" ]]; then
    echo "ERROR: ${label} failed."
    echo "$response" | jq '.errors // .'
    exit 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# CHECK DEPENDENCIES
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Checking dependencies..."
for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: ${cmd} is not installed."
    exit 1
  fi
done
echo "    OK"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: ENABLE EMAIL ROUTING
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 1: Email Routing (skipped - enabled manually in dashboard)"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: CREATE DNS CNAME FOR inbound.DOMAIN
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 2: Create DNS record for inbound.${DOMAIN}..."

# Get tunnel ID from local cloudflared config
TUNNEL_ID=$(grep '^tunnel:' "${SCRIPT_DIR}/cloudflared-config/config.yml" 2>/dev/null \
  | awk '{print $2}' || true)
if [[ -z "$TUNNEL_ID" ]]; then
  echo "ERROR: Could not read tunnel ID from cloudflared-config/config.yml"
  exit 1
fi
TUNNEL_TARGET="${TUNNEL_ID}.cfargotunnel.com"

existing_dns=$(cf_global GET "/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=inbound.${DOMAIN}" \
  | jq -r '.result[0].id // empty')

if [[ -n "$existing_dns" ]]; then
  echo "    CNAME for inbound.${DOMAIN} already exists (${existing_dns})."
else
  dns_response=$(cf_global POST "/zones/${CF_ZONE_ID}/dns_records" "{
    \"type\": \"CNAME\",
    \"name\": \"inbound\",
    \"content\": \"${TUNNEL_TARGET}\",
    \"ttl\": 60,
    \"proxied\": true
  }")
  check_success "$dns_response" "Create DNS record"
  echo "    CNAME created: inbound.${DOMAIN} -> ${TUNNEL_TARGET}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: DEPLOY EMAIL WORKER
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 3: Deploy Email Worker via API..."

if [[ ! -f "${WORKER_DIR}/email-worker.js" ]]; then
  echo "ERROR: worker/email-worker.js not found."
  exit 1
fi

deploy_response=$(
  curl -sf -X PUT \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/workers/scripts/email-ingest" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -F "metadata={\"main_module\":\"email-worker.js\",\"compatibility_date\":\"2024-01-01\",\"usage_model\":\"bundled\"};type=application/json" \
    -F "email-worker.js=@${WORKER_DIR}/email-worker.js;type=application/javascript+module"
)
check_success "$deploy_response" "Deploy Worker"
echo "    Worker deployed."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: SET WORKER SECRETS
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 4: Set Worker secrets..."

set_secret() {
  local name="$1"
  local value="$2"
  local response
  response=$(curl -sf -X PUT \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/workers/scripts/email-ingest/secrets" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{\"name\":\"${name}\",\"text\":\"${value}\",\"type\":\"secret_text\"}")
  check_success "$response" "Set secret ${name}"
  echo "    Set: ${name}"
}

set_secret "INGEST_URL"   "${INGEST_URL}"
set_secret "INGEST_TOKEN" "${INGEST_TOKEN}"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: CREATE INITIAL EMAIL ROUTING RULES
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 5: Create Email Routing rules..."

WORKER_NAME="email-ingest"

# Read the initial addresses from CALENDAR_MAP in config.env
# CALENDAR_MAP format: "addr1:/path/,addr2:/path/,..."
IFS=',' read -ra MAP_ENTRIES <<< "${CALENDAR_MAP}"

for entry in "${MAP_ENTRIES[@]}"; do
  entry="${entry// /}"
  address="${entry%%:*}"

  if [[ -z "$address" ]]; then
    continue
  fi

  # Check if a rule already exists for this address
  existing_rule=$(cf_bearer GET "/zones/${CF_ZONE_ID}/email/routing/rules" \
    | jq -r --arg addr "$address" \
      '.result[] | select(.matchers[0].value == $addr) | .id // empty' \
    | head -1)

  if [[ -n "$existing_rule" ]]; then
    echo "    Rule already exists for ${address} (${existing_rule})."
    continue
  fi

  rule_response=$(cf_bearer POST "/zones/${CF_ZONE_ID}/email/routing/rules" "{
    \"name\": \"Route ${address} to ingest worker\",
    \"enabled\": true,
    \"matchers\": [{
      \"type\": \"literal\",
      \"field\": \"to\",
      \"value\": \"${address}\"
    }],
    \"actions\": [{
      \"type\": \"worker\",
      \"value\": [\"${WORKER_NAME}\"]
    }]
  }")

  check_success "$rule_response" "Create rule for ${address}"
  rule_id=$(echo "$rule_response" | jq -r '.result.id')
  echo "    Created rule: ${address} -> ${WORKER_NAME} (${rule_id})"
done

# ─────────────────────────────────────────────────────────────────────────────
# DONE
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Cloudflare Email Routing setup complete.                       ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "Next steps:"
echo ""
echo "  1. Deploy the updated docker stack:"
echo "       scp docker-compose.yml cloudflared-config/config.yml nate@TheServer:/mnt/md0/docker/radicale/"
echo "       scp ingest.py nate@TheServer:/mnt/md0/docker/radicale/"
echo "       # on TheServer:"
echo "       cd /mnt/md0/docker/radicale && docker compose up -d --force-recreate"
echo ""
echo "  2. Set up Proton Mail auto-forward rules. For each address below,"
echo "     go to Settings > Filters > Forwarding in Proton Mail and create"
echo "     a rule to forward matching emails to the address shown:"
echo ""

for entry in "${MAP_ENTRIES[@]}"; do
  entry="${entry// /}"
  address="${entry%%:*}"
  [[ -z "$address" ]] && continue
  echo "       ${address}"
done

echo ""
echo "  3. Send a test email with an .ics attachment to one of the addresses"
echo "     and check: docker logs ingest -f"
echo ""
echo "  4. Once confirmed working, run ./remove-bridge.sh to clean up Bridge."
echo "     (That script does not exist yet — create it when ready.)"
