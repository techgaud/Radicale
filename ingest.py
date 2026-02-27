#!/usr/bin/env python3

# ─────────────────────────────────────────────────────────────────────────────
# ingest.py
#
# HTTP server that receives raw emails POSTed by the Cloudflare Email Worker,
# extracts .ics attachments, and pushes each event or task to the correct
# Radicale collection based on the destination email address.
#
# Runs as a Docker service inside the compose stack, reachable from cloudflared
# at http://ingest:8000. Exposed publicly at https://inbound.natecalvert.org.
#
# Endpoint:  POST /ingest
# Headers:
#   Content-Type: message/rfc822
#   X-Ingest-Token: <must match INGEST_TOKEN in config.env>
#   X-Destination: <destination email address, e.g. pickleball@natecalvert.org>
# Body: raw email bytes (RFC 822)
#
# Responses:
#   200  OK - N event(s) pushed
#   200  OK - no attachments  (email had no .ics — not an error)
#   400  Bad request (missing header or empty body)
#   403  Bad or missing token
#   422  Destination address not in CALENDAR_MAP
#   500  CalDAV push failed
#
# Collection types: VEVENT for calendar addresses, VTODO for task addresses.
# Determined by inspecting the BEGIN: line inside each .ics attachment.
# A single email can contain both types — each goes to the mapped collection.
#
# Config keys consumed from config.env:
#   INGEST_TOKEN         - shared secret with the Cloudflare Worker
#   RADICALE_INTERNAL_URL - base URL inside Docker, e.g. http://radicale:5232
#   RADICALE_USER        - CalDAV username
#   RADICALE_PASS        - CalDAV password
#   CALENDAR_MAP         - comma-separated addr:/path/ pairs
#                          e.g. "pickleball@natecalvert.org:/nate/bounce_calendar/,..."
#   INGEST_PORT          - optional, defaults to 8000
# ─────────────────────────────────────────────────────────────────────────────

import sys
import logging
import base64
import datetime
import urllib.request
import urllib.error
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
from email import policy
from email.parser import BytesParser
from pathlib import Path

# ─────────────────────────────────────────────────────────────────────────────
# LOAD CONFIG
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent.resolve()
CONFIG_FILE = SCRIPT_DIR / "config.env"

if not CONFIG_FILE.exists():
    print(f"ERROR: config.env not found at {CONFIG_FILE}")
    sys.exit(1)

config = {}
with open(CONFIG_FILE) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, raw_value = line.partition("=")
        key = key.strip()
        value = raw_value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
            value = value[1:-1]
        config[key] = value

required = [
    "INGEST_TOKEN", "RADICALE_INTERNAL_URL", "RADICALE_USER", "RADICALE_PASS",
    "CALENDAR_MAP",
]
missing = [k for k in required if not config.get(k)]
if missing:
    print(f"ERROR: Missing required config values: {', '.join(missing)}")
    sys.exit(1)

INGEST_TOKEN          = config["INGEST_TOKEN"]
RADICALE_INTERNAL_URL = config["RADICALE_INTERNAL_URL"].rstrip("/")
RADICALE_USER         = config["RADICALE_USER"]
RADICALE_PASS         = config["RADICALE_PASS"]
LISTEN_PORT           = int(config.get("INGEST_PORT", "8000"))

# Parse CALENDAR_MAP: "addr1:/path/1/,addr2:/path/2/"
CALENDAR_MAP = {}
for entry in config["CALENDAR_MAP"].split(","):
    entry = entry.strip()
    if ":" not in entry:
        continue
    addr, _, path = entry.partition(":")
    addr = addr.strip().lower()
    path = path.strip().rstrip("/") + "/"
    CALENDAR_MAP[addr] = path

if not CALENDAR_MAP:
    print("ERROR: CALENDAR_MAP is empty or malformed in config.env.")
    sys.exit(1)

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("ingest")

# ─────────────────────────────────────────────────────────────────────────────
# CALDAV HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def _auth_header() -> str:
    return "Basic " + base64.b64encode(
        f"{RADICALE_USER}:{RADICALE_PASS}".encode()
    ).decode()


def ensure_collection_exists(collection_path: str, component: str = "VEVENT") -> bool:
    """
    Create a Radicale calendar or task collection if it does not already exist.
    Checks with GET first — 404 means absent, anything else means present.
    MKCOL with 403/405 response also means already present.
    component is "VEVENT" for calendars, "VTODO" for task lists.
    """
    url = f"{RADICALE_INTERNAL_URL}{collection_path}"

    check = urllib.request.Request(
        url, method="GET",
        headers={"Authorization": _auth_header(), "User-Agent": "ingest/1.0"}
    )
    try:
        with urllib.request.urlopen(check):
            return True
    except urllib.error.HTTPError as e:
        if e.code != 404:
            return True

    # Collection absent — create it
    mkcol_body = f"""<?xml version="1.0" encoding="UTF-8"?>
<mkcol xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
  <set><prop>
    <resourcetype><collection/><C:calendar/></resourcetype>
    <C:supported-calendar-component-set>
      <C:comp name="{component}"/>
    </C:supported-calendar-component-set>
  </prop></set>
</mkcol>""".encode()

    req = urllib.request.Request(
        url, data=mkcol_body, method="MKCOL",
        headers={
            "Content-Type": "application/xml",
            "Authorization": _auth_header(),
            "User-Agent": "ingest/1.0",
        }
    )
    try:
        with urllib.request.urlopen(req):
            log.info(f"Created {component} collection at {url}")
            return True
    except urllib.error.HTTPError as e:
        if e.code in (403, 405):
            # Radicale returns 405 if it exists, 403 on some configs
            return True
        log.error(f"MKCOL failed for {url}: HTTP {e.code} {e.reason}")
        return False
    except urllib.error.URLError as e:
        log.error(f"MKCOL failed for {url}: {e.reason}")
        return False


def push_event(collection_path: str, uid: str, ics_data: bytes) -> bool:
    """
    PUT a single .ics to Radicale. Uses the UID as filename so re-delivery
    of the same event overwrites rather than duplicates.
    """
    safe_uid = urllib.parse.quote(uid, safe="")
    url = f"{RADICALE_INTERNAL_URL}{collection_path}{safe_uid}.ics"
    req = urllib.request.Request(
        url, data=ics_data, method="PUT",
        headers={
            "Content-Type": "text/calendar; charset=utf-8",
            "Authorization": _auth_header(),
            "User-Agent": "ingest/1.0",
        }
    )
    try:
        with urllib.request.urlopen(req) as resp:
            log.info(f"PUT {url} -> {resp.status}")
            return resp.status in (200, 201, 204)
    except urllib.error.HTTPError as e:
        log.error(f"PUT failed for UID {uid}: HTTP {e.code} {e.reason}")
        return False
    except urllib.error.URLError as e:
        log.error(f"PUT failed for UID {uid}: {e.reason}")
        return False

# ─────────────────────────────────────────────────────────────────────────────
# ICS HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def extract_ics_attachments(raw_email: bytes) -> list:
    """
    Walk a raw RFC 822 email and return a list of .ics payloads as bytes.
    Matches both text/calendar content-type and .ics filename.
    """
    msg = BytesParser(policy=policy.default).parsebytes(raw_email)
    attachments = []
    for part in msg.walk():
        ct = part.get_content_type()
        fn = (part.get_filename() or "").lower()
        if ct == "text/calendar" or fn.endswith(".ics"):
            payload = part.get_payload(decode=True)
            if payload:
                attachments.append(payload)
    return attachments


def detect_component(ics_data: bytes) -> str:
    """
    Return 'VTODO' if the .ics contains a task, 'VEVENT' otherwise.
    Inspects the BEGIN: line — works for standard ICS files.
    """
    for line in ics_data.decode("utf-8", errors="replace").splitlines():
        stripped = line.strip()
        if stripped == "BEGIN:VTODO":
            return "VTODO"
    return "VEVENT"


def extract_uid(ics_data: bytes) -> str:
    """
    Pull the UID from inside the .ics. Falls back to a timestamp-based
    value so there is always a usable filename.
    """
    for line in ics_data.decode("utf-8", errors="replace").splitlines():
        if line.startswith("UID:"):
            return line[4:].strip()
    return f"ingest-{datetime.datetime.utcnow().strftime('%Y%m%dT%H%M%SZ')}"

# ─────────────────────────────────────────────────────────────────────────────
# HTTP HANDLER
# ─────────────────────────────────────────────────────────────────────────────

class IngestHandler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        log.info(f"{self.address_string()} - {fmt % args}")

    def send_text(self, code: int, body: str):
        encoded = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_POST(self):
        if self.path != "/ingest":
            self.send_text(404, "Not found")
            return

        # ── Auth ──────────────────────────────────────────────────────────────
        token = self.headers.get("X-Ingest-Token", "")
        if token != INGEST_TOKEN:
            log.warning(f"Rejected request with bad or missing token from {self.address_string()}")
            self.send_text(403, "Forbidden")
            return

        # ── Destination → collection path ────────────────────────────────────
        destination = self.headers.get("X-Destination", "").strip().lower()
        if not destination:
            self.send_text(400, "Missing X-Destination header")
            return

        collection_path = CALENDAR_MAP.get(destination)
        if not collection_path:
            log.warning(f"No collection mapped for: {destination}")
            self.send_text(422, f"No calendar mapped for {destination}")
            return

        # ── Read body ─────────────────────────────────────────────────────────
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            self.send_text(400, "Empty body")
            return
        raw_email = self.rfile.read(length)

        # ── Extract ICS attachments ───────────────────────────────────────────
        attachments = extract_ics_attachments(raw_email)
        if not attachments:
            log.info(f"No .ics attachments in email to {destination} — nothing to do")
            self.send_text(200, "OK - no attachments")
            return

        log.info(f"Processing {len(attachments)} attachment(s) for {destination} -> {collection_path}")

        # ── Push each attachment ──────────────────────────────────────────────
        errors = []
        pushed = 0
        for ics_data in attachments:
            component = detect_component(ics_data)
            if not ensure_collection_exists(collection_path, component):
                errors.append(f"Cannot ensure collection {collection_path}")
                continue
            uid = extract_uid(ics_data)
            if push_event(collection_path, uid, ics_data):
                pushed += 1
            else:
                errors.append(f"Failed to push UID {uid}")

        if errors:
            log.error(f"Errors for {destination}: {errors}")
            self.send_text(500, "Errors: " + "; ".join(errors))
        else:
            self.send_text(200, f"OK - pushed {pushed} event(s)")

    def do_GET(self):
        # Health check so cloudflared / monitoring can verify the service is up
        if self.path == "/health":
            self.send_text(200, "OK")
        else:
            self.send_text(404, "Not found")

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    log.info(f"Ingest server starting on 0.0.0.0:{LISTEN_PORT}")
    log.info(f"Loaded {len(CALENDAR_MAP)} calendar mapping(s):")
    for addr, path in CALENDAR_MAP.items():
        log.info(f"  {addr} -> {path}")
    server = HTTPServer(("0.0.0.0", LISTEN_PORT), IngestHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down.")
