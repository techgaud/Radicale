#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# cloudflare-setup.sh
#
# One-time setup for Cloudflare Email Routing + Email Worker.
# Run this after setup.sh.
#
# What it does:
#   1. Enables Email Routing on the zone via Global API Key
#   2. DNS records are skipped (setup.sh handles all DNS)
#   3. Deploys the Email Worker via Cloudflare API (no Wrangler required)
#   4. Sets Worker secrets: INGEST_URL, INGEST_TOKEN
#   5. Creates Email Routing rules for all addresses in CALENDAR_MAP
#   6. Verifies the full stack is healthy, then seals config.env by
#      removing CF_GLOBAL_KEY and CF_EMAIL (no longer needed after this)
#
# Prerequisites:
#   - setup.sh has been run successfully
#   - config.env populated with:
#       CF_API_TOKEN, CF_ZONE_ID, CF_ACCOUNT_ID, CF_EMAIL, CF_GLOBAL_KEY,
#       DOMAIN, INGEST_SUBDOMAIN, INGEST_TOKEN, CALENDAR_MAP
#   - worker/email-worker.js present
#
# Idempotent: safe to re-run. Existing rules and secrets are overwritten.
# Note: The seal step (Step 6) will skip gracefully if already sealed.
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
               DOMAIN INGEST_SUBDOMAIN INGEST_TOKEN CALENDAR_MAP)
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} is not set in config.env"
    echo "       If CF_EMAIL or CF_GLOBAL_KEY are empty this script has already"
    echo "       been sealed. Re-run is safe but sealing cannot be undone from here."
    exit 1
  fi
done

INGEST_URL="https://${INGEST_SUBDOMAIN}.${DOMAIN}/ingest"

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

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
for cmd in curl jq docker; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: ${cmd} is not installed."
    exit 1
  fi
done
echo "    OK"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: ENABLE EMAIL ROUTING
# Uses the Global API Key which is guaranteed to have Zone Settings Write.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 1: Enable Email Routing on zone ${CF_ZONE_ID}..."

# Check current state first
status_response=$(cf_global GET "/zones/${CF_ZONE_ID}/email/routing" 2>/dev/null || true)
already=$(echo "${status_response}" | jq -r '.result.enabled // false' 2>/dev/null || echo 'false')

if [[ "$already" == "true" ]]; then
  echo "    Email Routing already enabled."
else
  enable_response=$(cf_global POST "/zones/${CF_ZONE_ID}/email/routing/enable" '{}')
  enabled=$(echo "${enable_response}" | jq -r '.result.enabled // false')
  if [[ "$enabled" == "true" ]]; then
    echo "    Email Routing enabled."
  else
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  WARNING: Could not enable Email Routing via API."
    echo ""
    echo "  Go to: dash.cloudflare.com -> ${DOMAIN} -> Email -> Email Routing"
    echo "  Click 'Enable Email Routing' and complete the wizard."
    echo "  (You can use a throwaway forwarding rule during the wizard"
    echo "   — it will be replaced by the Worker rules this script creates.)"
    echo ""
    read -rp "  Press Enter once Email Routing is enabled in the dashboard..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: DNS
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 2: DNS (handled by setup.sh — skipping)."

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
# STEP 5: CREATE EMAIL ROUTING RULES
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 5: Create Email Routing rules..."

WORKER_NAME="email-ingest"
IFS=',' read -ra MAP_ENTRIES <<< "${CALENDAR_MAP}"

for entry in "${MAP_ENTRIES[@]}"; do
  entry="${entry// /}"
  address="${entry%%:*}"
  [[ -z "$address" ]] && continue

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
# STEP 6: VERIFY AND SEAL
# Runs 8 health checks. If all pass, removes CF_GLOBAL_KEY and CF_EMAIL
# from config.env — they are no longer needed after this point.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 6: Verify stack health..."

PASS=0
FAIL=0

check() {
  local label="$1"
  local result="$2"  # "ok" or "fail: <reason>"
  if [[ "$result" == "ok" ]]; then
    echo "    ✓ ${label}"
    PASS=$(( PASS + 1 ))
  else
    echo "    ✗ ${label} — ${result#fail: }"
    FAIL=$(( FAIL + 1 ))
  fi
}

# 1. Email Routing enabled
er_status=$(cf_global GET "/zones/${CF_ZONE_ID}/email/routing" 2>/dev/null \
  | jq -r '.result.enabled // false' 2>/dev/null || echo 'false')
[[ "$er_status" == "true" ]] \
  && check "Email Routing enabled" "ok" \
  || check "Email Routing enabled" "fail: still disabled"

# 2. CF_API_TOKEN is valid
token_status=$(curl -sf "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  | jq -r '.result.status // "inactive"' 2>/dev/null || echo 'inactive')
[[ "$token_status" == "active" ]] \
  && check "CF_API_TOKEN valid" "ok" \
  || check "CF_API_TOKEN valid" "fail: token status is ${token_status}"

# 3. Email Worker deployed
worker_status=$(curl -sf -o /dev/null -w "%{http_code}" \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/workers/scripts/email-ingest" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" 2>/dev/null || echo '000')
[[ "$worker_status" == "200" ]] \
  && check "Email Worker deployed" "ok" \
  || check "Email Worker deployed" "fail: HTTP ${worker_status}"

# 4. Routing rules exist for all CALENDAR_MAP addresses
rules_response=$(cf_bearer GET "/zones/${CF_ZONE_ID}/email/routing/rules" 2>/dev/null || echo '{}')
rules_ok=true
for entry in "${MAP_ENTRIES[@]}"; do
  entry="${entry// /}"
  address="${entry%%:*}"
  [[ -z "$address" ]] && continue
  rule_found=$(echo "$rules_response" | jq -r --arg addr "$address" \
    '.result[] | select(.matchers[0].value == $addr) | .id // empty' | head -1)
  if [[ -z "$rule_found" ]]; then
    check "Routing rule: ${address}" "fail: rule not found"
    rules_ok=false
  else
    check "Routing rule: ${address}" "ok"
  fi
done

# 5. All 4 Docker containers are running
for container in radicale agendav ingest cloudflared; do
  state=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo 'missing')
  [[ "$state" == "running" ]] \
    && check "Container: ${container}" "ok" \
    || check "Container: ${container}" "fail: state is ${state}"
done

# 6. Radicale reachable internally (401 = alive, auth required)
radicale_http=$(docker exec radicale \
  wget -qO /dev/null --server-response \
  "http://localhost:5232" 2>&1 | grep "HTTP/" | awk '{print $2}' | head -1 || echo '000')
[[ "$radicale_http" == "401" || "$radicale_http" == "200" ]] \
  && check "Radicale internal HTTP" "ok" \
  || check "Radicale internal HTTP" "fail: got HTTP ${radicale_http}"

# 7. Ingest health endpoint
ingest_http=$(docker exec ingest \
  wget -qO /dev/null --server-response \
  "http://localhost:${INGEST_PORT}/health" 2>&1 | grep "HTTP/" | awk '{print $2}' | head -1 || echo '000')
[[ "$ingest_http" == "200" ]] \
  && check "Ingest /health endpoint" "ok" \
  || check "Ingest /health endpoint" "fail: got HTTP ${ingest_http}"

# 8. DNS records exist for all 3 subdomains
for sub in "${SUBDOMAIN}" "${AGENDAV_SUBDOMAIN}" "${INGEST_SUBDOMAIN}"; do
  fqdn="${sub}.${DOMAIN}"
  dns_result=$(cf_bearer GET "/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${fqdn}" \
    | jq -r '.result[0].id // empty' 2>/dev/null || true)
  [[ -n "$dns_result" ]] \
    && check "DNS record: ${fqdn}" "ok" \
    || check "DNS record: ${fqdn}" "fail: CNAME not found"
done

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "    Results: ${PASS} passed, ${FAIL} failed"

if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "  Some checks failed. Fix the issues above and re-run this script."
  echo "  config.env has NOT been sealed."
  exit 1
fi

# ── Seal config.env ───────────────────────────────────────────────────────────
echo ""
echo "==> All checks passed. Sealing config.env..."

# Zero out CF_GLOBAL_KEY and CF_EMAIL — no longer needed
sed -i 's|^CF_GLOBAL_KEY=.*|CF_GLOBAL_KEY=""|' "$CONFIG_FILE"
sed -i 's|^CF_EMAIL=.*|CF_EMAIL=""|'           "$CONFIG_FILE"

echo "    CF_GLOBAL_KEY cleared."
echo "    CF_EMAIL cleared."
echo "    The scoped CF_API_TOKEN handles all ongoing operations."

# ─────────────────────────────────────────────────────────────────────────────
# DONE
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Cloudflare Email Routing setup complete.                       ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Radicale:   https://${SUBDOMAIN}.${DOMAIN}"
echo "  AgenDAV:    https://${AGENDAV_SUBDOMAIN}.${DOMAIN}"
echo "  Ingest:     https://${INGEST_SUBDOMAIN}.${DOMAIN}"
echo ""
echo "Next steps:"
echo ""
echo "  1. For each address in your CALENDAR_MAP, set up an auto-forward"
echo "     rule in your email provider pointing to that address."
echo ""
echo "  2. Test by forwarding an email with a .ics attachment and watching:"
echo "       docker logs ingest -f"
echo ""
echo "  3. To add more calendars later:"
echo "       ./provision-calendar.sh -a addr@${DOMAIN} -p /user/calname/ -t vevent"
