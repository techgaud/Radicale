#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# create-subdomain.sh
#
# Creates a Cloudflare CNAME record pointing a subdomain at the existing
# Cloudflare Tunnel. Reads credentials and defaults from config.env.
#
# Usage:
#   ./create-subdomain.sh                      # uses SUBDOMAIN and DOMAIN from config.env
#   ./create-subdomain.sh -s calendar          # override subdomain
#   ./create-subdomain.sh -s calendar -d example.com   # override both
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# LOAD CONFIG
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config.env not found at ${CONFIG_FILE}"
  exit 1
fi

source "$CONFIG_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# PARSE FLAGS
# ─────────────────────────────────────────────────────────────────────────────
SUB="${SUBDOMAIN:-}"
DOM="${DOMAIN:-}"

while getopts "s:d:" opt; do
  case "$opt" in
    s) SUB="$OPTARG" ;;
    d) DOM="$OPTARG" ;;
    *) echo "Usage: $0 [-s subdomain] [-d domain]"; exit 1 ;;
  esac
done

if [[ -z "$SUB" ]]; then
  echo "ERROR: No subdomain specified and SUBDOMAIN not set in config.env."
  echo "Usage: $0 -s <subdomain> [-d <domain>]"
  exit 1
fi

if [[ -z "$DOM" ]]; then
  echo "ERROR: No domain specified and DOMAIN not set in config.env."
  echo "Usage: $0 [-s <subdomain>] -d <domain>"
  exit 1
fi

FQDN="${SUB}.${DOM}"

# ─────────────────────────────────────────────────────────────────────────────
# VALIDATE CREDENTIALS
# ─────────────────────────────────────────────────────────────────────────────
if [[ -z "${CF_EMAIL:-}" || -z "${CF_GLOBAL_KEY:-}" ]]; then
  echo "ERROR: CF_EMAIL and CF_GLOBAL_KEY must be set in config.env."
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# HELPER: Cloudflare API call
# ─────────────────────────────────────────────────────────────────────────────
cf_api() {
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
# LOOK UP ZONE ID
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Looking up zone ID for ${DOM}..."
ZONE_ID=$(cf_api GET "/zones?name=${DOM}" | jq -r '.result[0].id // empty')

if [[ -z "$ZONE_ID" ]]; then
  echo "ERROR: Zone not found for ${DOM}. Is it added to Cloudflare?"
  exit 1
fi
echo "    Zone ID: ${ZONE_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# LOOK UP TUNNEL ID
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Looking up tunnel ID..."
TUNNEL_NAME="${TUNNEL_NAME:-}"

if [[ -z "$TUNNEL_NAME" ]]; then
  echo "ERROR: TUNNEL_NAME not set in config.env."
  exit 1
fi

TUNNEL_ID=$(cf_api GET "/accounts/$(cf_api GET "/accounts" | jq -r '.result[0].id')/cfd_tunnel?name=${TUNNEL_NAME}" \
  | jq -r '.result[0].id // empty')

if [[ -z "$TUNNEL_ID" ]]; then
  # Fall back to parsing the local cloudflared config
  LOCAL_TUNNEL_ID=$(grep '^tunnel:' "${SCRIPT_DIR}/cloudflared-config/config.yml" 2>/dev/null \
    | awk '{print $2}' || true)
  if [[ -n "$LOCAL_TUNNEL_ID" ]]; then
    TUNNEL_ID="$LOCAL_TUNNEL_ID"
  else
    echo "ERROR: Could not determine tunnel ID from API or local config."
    exit 1
  fi
fi
echo "    Tunnel ID: ${TUNNEL_ID}"

TUNNEL_TARGET="${TUNNEL_ID}.cfargotunnel.com"

# ─────────────────────────────────────────────────────────────────────────────
# CHECK IF RECORD ALREADY EXISTS
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Checking if ${FQDN} already exists..."
EXISTING=$(cf_api GET "/zones/${ZONE_ID}/dns_records?type=CNAME&name=${FQDN}" \
  | jq -r '.result[0].id // empty')

if [[ -n "$EXISTING" ]]; then
  echo "    Record already exists for ${FQDN}."
  echo ""
  echo "    URL:       https://${FQDN}"
  echo "    Record ID: ${EXISTING}"
  echo "    Target:    ${TUNNEL_TARGET}"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# CREATE CNAME RECORD
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Creating CNAME record for ${FQDN}..."
RESPONSE=$(cf_api POST "/zones/${ZONE_ID}/dns_records" "{
  \"type\": \"CNAME\",
  \"name\": \"${SUB}\",
  \"content\": \"${TUNNEL_TARGET}\",
  \"ttl\": 60,
  \"proxied\": true
}")

SUCCESS=$(echo "$RESPONSE" | jq -r '.success')
RECORD_ID=$(echo "$RESPONSE" | jq -r '.result.id // empty')

if [[ "$SUCCESS" != "true" ]]; then
  echo "ERROR: Failed to create DNS record."
  echo "$RESPONSE" | jq '.errors'
  exit 1
fi

echo "    Record created."
echo ""
echo "    URL:       https://${FQDN}"
echo "    Record ID: ${RECORD_ID}"
echo "    Target:    ${TUNNEL_TARGET}"
echo ""
echo "    Remember to add an ingress rule for ${FQDN} in"
echo "    cloudflared-config/config.yml and restart the stack."
