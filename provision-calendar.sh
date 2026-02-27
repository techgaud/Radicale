#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# provision-calendar.sh
#
# Adds a new calendar or task list end-to-end. Run this whenever you want
# to add a new inbound email address and its corresponding Radicale collection.
#
# What it does:
#   1. Creates a Cloudflare Email Routing rule: address -> email-ingest Worker
#   2. Creates the Radicale collection via CalDAV MKCALENDAR
#   3. Adds the address:path mapping to CALENDAR_MAP in config.env
#   4. Restarts the ingest Docker container to pick up the new mapping
#   5. Prints the Proton Mail forward instruction
#
# Usage:
#   ./provision-calendar.sh -a appointments@natecalvert.org \
#                           -p /nate/appointments/ \
#                           -t vevent
#
#   ./provision-calendar.sh -a tasks@natecalvert.org \
#                           -p /nate/tasks/ \
#                           -t vtodo
#
# Flags:
#   -a  Email address to route  (required)
#   -p  Radicale collection path, e.g. /nate/appointments/  (required)
#   -t  Collection type: vevent (calendar) or vtodo (tasks)  (default: vevent)
#
# Idempotent: each step checks before acting. Safe to re-run.
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

# ─────────────────────────────────────────────────────────────────────────────
# PARSE FLAGS
# ─────────────────────────────────────────────────────────────────────────────
ADDRESS=""
COLLECTION_PATH=""
COMPONENT_TYPE="VEVENT"

while getopts "a:p:t:" opt; do
  case "$opt" in
    a) ADDRESS="$OPTARG" ;;
    p) COLLECTION_PATH="$OPTARG" ;;
    t)
      case "${OPTARG,,}" in
        vevent) COMPONENT_TYPE="VEVENT" ;;
        vtodo)  COMPONENT_TYPE="VTODO" ;;
        *)
          echo "ERROR: -t must be 'vevent' or 'vtodo'"
          exit 1
          ;;
      esac
      ;;
    *)
      echo "Usage: $0 -a <email@domain> -p </radicale/path/> [-t vevent|vtodo]"
      exit 1
      ;;
  esac
done

if [[ -z "$ADDRESS" || -z "$COLLECTION_PATH" ]]; then
  echo "ERROR: -a and -p are required."
  echo "Usage: $0 -a <email@domain> -p </radicale/path/> [-t vevent|vtodo]"
  exit 1
fi

ADDRESS="${ADDRESS,,}"
COLLECTION_PATH="${COLLECTION_PATH%/}/"  # ensure trailing slash

# ─────────────────────────────────────────────────────────────────────────────
# LOAD CONFIG
# ─────────────────────────────────────────────────────────────────────────────
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config.env not found at ${CONFIG_FILE}"
  exit 1
fi
source "$CONFIG_FILE"

required_vars=(CF_API_TOKEN CF_ZONE_ID RADICALE_INTERNAL_URL RADICALE_USER RADICALE_PASS)
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} is not set in config.env"
    exit 1
  fi
done

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

radicale_request() {
  local method="$1"
  local path="$2"
  local content_type="${3:-}"
  local data="${4:-}"

  local url="${RADICALE_INTERNAL_URL%/}${path}"
  local auth
  auth=$(printf '%s:%s' "$RADICALE_USER" "$RADICALE_PASS" | base64)

  local curl_args=(-sf -X "$method" "$url" \
    -H "Authorization: Basic ${auth}" \
    -H "User-Agent: provision-calendar/1.0" \
    -o /dev/null -w "%{http_code}")

  if [[ -n "$content_type" ]]; then
    curl_args+=(-H "Content-Type: ${content_type}")
  fi
  if [[ -n "$data" ]]; then
    curl_args+=(--data "$data")
  fi

  curl "${curl_args[@]}"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: CREATE EMAIL ROUTING RULE
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 1: Create Email Routing rule for ${ADDRESS}..."

WORKER_NAME="email-ingest"

existing_rule=$(cf_bearer GET "/zones/${CF_ZONE_ID}/email/routing/rules" \
  | jq -r --arg addr "$ADDRESS" \
    '.result[] | select(.matchers[0].value == $addr) | .id // empty' \
  | head -1)

if [[ -n "$existing_rule" ]]; then
  echo "    Rule already exists (${existing_rule}). Skipping."
else
  rule_response=$(cf_bearer POST "/zones/${CF_ZONE_ID}/email/routing/rules" "{
    \"name\": \"Route ${ADDRESS} to ingest worker\",
    \"enabled\": true,
    \"matchers\": [{
      \"type\": \"literal\",
      \"field\": \"to\",
      \"value\": \"${ADDRESS}\"
    }],
    \"actions\": [{
      \"type\": \"worker\",
      \"value\": [\"${WORKER_NAME}\"]
    }]
  }")
  check_success "$rule_response" "Create routing rule"
  rule_id=$(echo "$rule_response" | jq -r '.result.id')
  echo "    Rule created: ${ADDRESS} -> ${WORKER_NAME} (${rule_id})"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: CREATE RADICALE COLLECTION
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 2: Create Radicale ${COMPONENT_TYPE} collection at ${COLLECTION_PATH}..."

# Check if collection already exists
http_code=$(radicale_request GET "$COLLECTION_PATH")

if [[ "$http_code" != "404" ]]; then
  echo "    Collection already exists (HTTP ${http_code}). Skipping."
else
  mkcol_body="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<mkcol xmlns=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\">
  <set><prop>
    <resourcetype><collection/><C:calendar/></resourcetype>
    <C:supported-calendar-component-set>
      <C:comp name=\"${COMPONENT_TYPE}\"/>
    </C:supported-calendar-component-set>
  </prop></set>
</mkcol>"

  http_code=$(radicale_request MKCOL "$COLLECTION_PATH" \
    "application/xml" "$mkcol_body")

  case "$http_code" in
    201|200)
      echo "    Collection created at ${COLLECTION_PATH}"
      ;;
    403|405)
      echo "    Collection already exists (HTTP ${http_code}). Skipping."
      ;;
    *)
      echo "ERROR: MKCALENDAR returned HTTP ${http_code} for ${COLLECTION_PATH}"
      exit 1
      ;;
  esac
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: ADD MAPPING TO config.env
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 3: Update CALENDAR_MAP in config.env..."

current_map="${CALENDAR_MAP:-}"
new_entry="${ADDRESS}:${COLLECTION_PATH}"

# Check if this address is already in the map
if echo "$current_map" | grep -q "${ADDRESS}:"; then
  echo "    ${ADDRESS} already in CALENDAR_MAP. Skipping."
else
  if [[ -z "$current_map" ]]; then
    new_map="$new_entry"
  else
    new_map="${current_map},${new_entry}"
  fi

  # Replace the CALENDAR_MAP line in config.env
  # Use a temp file to avoid sed -i portability issues
  tmp_file=$(mktemp)
  grep -v '^CALENDAR_MAP=' "$CONFIG_FILE" > "$tmp_file"
  echo "CALENDAR_MAP=\"${new_map}\"" >> "$tmp_file"
  mv "$tmp_file" "$CONFIG_FILE"

  echo "    CALENDAR_MAP updated."
  echo "    New entry: ${new_entry}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: RESTART INGEST CONTAINER
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 4: Restart ingest container..."
echo ""
echo "    Run the following on TheServer:"
echo ""
echo "      cd /mnt/md0/docker/radicale"
echo "      scp your-dev-machine:F:/Projects/Radicale/config.env ."
echo "      docker compose restart ingest"
echo ""
echo "    Or if you are running this script directly on TheServer:"
echo "      cd /mnt/md0/docker/radicale && docker compose restart ingest"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: PROTON MAIL INSTRUCTION
# ─────────────────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Manual step required: Proton Mail auto-forward                 ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Proton has no API, so this step is always manual."
echo ""
echo "  In Proton Mail web:"
echo "    Settings > Filters > Add filter"
echo ""
echo "  Forward emails TO: ${ADDRESS}"
echo "    - OR -"
echo "  Set up auto-forward for messages matching your criteria"
echo "  and forward them to: ${ADDRESS}"
echo ""
echo "  That's it. Emails forwarded to ${ADDRESS} will now be"
echo "  routed through Cloudflare to the ingest server and pushed"
echo "  into: ${RADICALE_INTERNAL_URL%/}${COLLECTION_PATH}"
echo ""
echo "  Verify with: docker logs ingest -f"
echo "  then send a test email with an .ics attachment to ${ADDRESS}."
