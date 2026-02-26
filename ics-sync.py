#!/usr/bin/env python3

# ─────────────────────────────────────────────────────────────────────────────
# ics-sync.sh
#
# Fired by goimapnotify the moment new mail arrives in the watched folder.
# Connects to Bridge's local IMAP, finds unprocessed emails with .ics
# attachments, pushes each event to Radicale via CalDAV PUT, deletes the
# email from the folder, and records the Message-ID in the sync log.
#
# This script is intentionally self-contained. It reads config.env from
# the same directory so it can run unattended without any arguments.
#
# Logging behaviour:
#   Each processed Message-ID is appended to ICS_SYNC_LOG with a timestamp.
#   On startup the script reads this log to build a skip-list, ensuring that
#   emails already handled in a previous run are never processed twice even
#   if the IMAP delete did not complete cleanly.
#
# Error handling:
#   If a CalDAV PUT fails the email is not deleted and the Message-ID is not
#   logged, so the next run will retry it. This means the worst case for a
#   transient error is a duplicate attempt, not a lost event.
# ─────────────────────────────────────────────────────────────────────────────

import os
import sys
import email
import logging
import datetime
import imaplib
import smtplib
import re
from pathlib import Path
from email import policy
from email.parser import BytesParser

try:
    from imapclient import IMAPClient
except ImportError:
    print("ERROR: imapclient is not installed. Run check-deps.sh first.")
    sys.exit(1)

try:
    import urllib.request
    import urllib.error
    import urllib.parse
    import base64
except ImportError:
    print("ERROR: urllib is not available. This should not happen on Python 3.")
    sys.exit(1)

# ─────────────────────────────────────────────────────────────────────────────
# LOAD CONFIG
# Reads config.env from the same directory as this script.
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
        # Skip comments and blank lines
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        # Split only on the FIRST equals sign so values containing = are safe.
        # Strip surrounding quotes that bash config files typically use.
        key, _, raw_value = line.partition("=")
        key = key.strip()
        # Remove a single layer of surrounding double or single quotes
        value = raw_value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
            value = value[1:-1]
        config[key] = value

required = [
    "PROTON_EMAIL", "PROTON_FOLDER", "BRIDGE_IMAP_PORT", "BRIDGE_IMAP_PASS",
    "RADICALE_CALENDAR_URL", "RADICALE_USER", "RADICALE_PASS", "ICS_SYNC_LOG"
]

missing = [k for k in required if not config.get(k)]
if missing:
    print(f"ERROR: Missing required config values: {', '.join(missing)}")
    sys.exit(1)

PROTON_EMAIL        = config["PROTON_EMAIL"]
PROTON_FOLDER       = config["PROTON_FOLDER"]
BRIDGE_IMAP_PORT    = int(config["BRIDGE_IMAP_PORT"])
BRIDGE_IMAP_PASS    = config["BRIDGE_IMAP_PASS"]
RADICALE_URL        = config["RADICALE_CALENDAR_URL"].rstrip("/") + "/"
RADICALE_USER       = config["RADICALE_USER"]
RADICALE_PASS       = config["RADICALE_PASS"]
ICS_SYNC_LOG        = Path(config["ICS_SYNC_LOG"])
if not ICS_SYNC_LOG.is_absolute():
    ICS_SYNC_LOG = (SCRIPT_DIR / ICS_SYNC_LOG).resolve()

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.StreamHandler(sys.stdout),
    ]
)
log = logging.getLogger("ics-sync")

# ─────────────────────────────────────────────────────────────────────────────
# LOAD PROCESSED MESSAGE IDS
# Build a set of Message-IDs that have already been handled so we never
# process the same email twice even if the IMAP delete failed previously.
# ─────────────────────────────────────────────────────────────────────────────
processed_ids = set()

if ICS_SYNC_LOG.exists():
    with open(ICS_SYNC_LOG) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            # Log format: 2024-01-01 12:00:00  <message-id>
            parts = line.split(None, 2)
            if len(parts) == 3:
                processed_ids.add(parts[2])

log.info(f"Loaded {len(processed_ids)} previously processed message IDs from log.")

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def ensure_calendar_exists() -> bool:
    """
    Create the Radicale calendar collection if it does not already exist.
    Uses MKCOL with a CalDAV resourcetype. Safe to call on every run —
    if the collection already exists Radicale returns 405 which we ignore.
    """
    credentials = base64.b64encode(
        f"{RADICALE_USER}:{RADICALE_PASS}".encode()
    ).decode()

    mkcol_body = """<?xml version="1.0" encoding="UTF-8"?>
<mkcol xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
  <set>
    <prop>
      <resourcetype>
        <collection/>
        <C:calendar/>
      </resourcetype>
    </prop>
  </set>
</mkcol>""".encode()

    request = urllib.request.Request(
        RADICALE_URL,
        data=mkcol_body,
        method="MKCOL",
        headers={
            "Content-Type": "application/xml",
            "Authorization": f"Basic {credentials}",
            "User-Agent": "ics-sync/1.0",
        }
    )

    # First check if the collection already exists with a GET
    credentials = base64.b64encode(
        f"{RADICALE_USER}:{RADICALE_PASS}".encode()
    ).decode()
    get_request = urllib.request.Request(
        RADICALE_URL,
        method="GET",
        headers={"Authorization": f"Basic {credentials}", "User-Agent": "ics-sync/1.0"}
    )
    try:
        with urllib.request.urlopen(get_request) as response:
            log.info("Calendar collection already exists.")
            return True
    except urllib.error.HTTPError as e:
        if e.code != 404:
            # Exists but returned something unexpected — try to proceed anyway
            log.info(f"Calendar collection check returned {e.code}, assuming it exists.")
            return True
        # 404 means it doesn't exist, fall through to MKCOL

    try:
        with urllib.request.urlopen(request) as response:
            log.info(f"Calendar collection created at {RADICALE_URL}")
            return True
    except urllib.error.HTTPError as e:
        if e.code in (405, 403):
            log.info("Calendar collection already exists.")
            return True
        log.error(f"Failed to create calendar collection: HTTP {e.code} {e.reason}")
        return False
    except urllib.error.URLError as e:
        log.error(f"Failed to create calendar collection: {e.reason}")
        return False


def push_to_radicale(uid: str, ics_data: bytes) -> bool:
    """
    Push a single .ics file to Radicale via CalDAV PUT.
    Uses the UID from inside the .ics as the filename, which means
    re-pushing the same event overwrites it rather than creating a duplicate.
    Returns True on success, False on failure.
    """
    safe_uid = urllib.parse.quote(uid, safe="")
    url = f"{RADICALE_URL}{safe_uid}.ics"
    credentials = base64.b64encode(
        f"{RADICALE_USER}:{RADICALE_PASS}".encode()
    ).decode()

    request = urllib.request.Request(
        url,
        data=ics_data,
        method="PUT",
        headers={
            "Content-Type": "text/calendar; charset=utf-8",
            "Authorization": f"Basic {credentials}",
            "User-Agent": "ics-sync/1.0",
        }
    )

    try:
        with urllib.request.urlopen(request) as response:
            log.info(f"PUT {url} -> {response.status}")
            return response.status in (200, 201, 204)
    except urllib.error.HTTPError as e:
        log.error(f"CalDAV PUT failed for UID {uid}: HTTP {e.code} {e.reason}")
        return False
    except urllib.error.URLError as e:
        log.error(f"CalDAV PUT failed for UID {uid}: {e.reason}")
        return False


def extract_uid(ics_data: bytes) -> str:
    """
    Extract the UID field from a .ics file.
    Falls back to a timestamp-based UID if none is found.
    """
    for line in ics_data.decode("utf-8", errors="replace").splitlines():
        if line.startswith("UID:"):
            return line[4:].strip()
    return f"ics-sync-{datetime.datetime.utcnow().strftime('%Y%m%dT%H%M%SZ')}"


def log_processed(message_id: str):
    """
    Append a successfully processed Message-ID to the sync log.
    Format: YYYY-MM-DD HH:MM:SS  <message-id>
    """
    timestamp = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
    with open(ICS_SYNC_LOG, "a") as f:
        f.write(f"{timestamp}  {message_id}\n")

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
def main():
    if not ensure_calendar_exists():
        log.error("Cannot proceed without a valid Radicale calendar collection.")
        sys.exit(1)

    log.info(f"Connecting to Bridge IMAP at 127.0.0.1:{BRIDGE_IMAP_PORT}...")

    try:
        with IMAPClient("127.0.0.1", port=BRIDGE_IMAP_PORT, ssl=False) as client:
            client.login(PROTON_EMAIL, BRIDGE_IMAP_PASS)
            log.info("Logged in to Bridge IMAP.")

            client.select_folder(PROTON_FOLDER)
            messages = client.search("ALL")
            log.info(f"Found {len(messages)} message(s) in {PROTON_FOLDER}.")

            for msg_id in messages:
                # Fetch the full message
                raw = client.fetch([msg_id], ["RFC822", "ENVELOPE"])
                raw_bytes = raw[msg_id][b"RFC822"]
                envelope = raw[msg_id][b"ENVELOPE"]

                # Extract Message-ID for deduplication
                message_id_header = envelope.message_id
                if isinstance(message_id_header, bytes):
                    message_id_header = message_id_header.decode("utf-8", errors="replace")

                if message_id_header in processed_ids:
                    log.info(f"Skipping already processed message: {message_id_header}")
                    continue

                # Parse the email
                msg = BytesParser(policy=policy.default).parsebytes(raw_bytes)

                # Find .ics attachments
                ics_attachments = []
                for part in msg.walk():
                    content_type = part.get_content_type()
                    filename = part.get_filename() or ""
                    if content_type == "text/calendar" or filename.endswith(".ics"):
                        ics_attachments.append(part.get_payload(decode=True))

                if not ics_attachments:
                    log.info(f"No .ics attachments found in message {message_id_header}, skipping.")
                    continue

                log.info(f"Found {len(ics_attachments)} .ics attachment(s) in {message_id_header}.")

                # Push each attachment to Radicale
                all_succeeded = True
                for ics_data in ics_attachments:
                    uid = extract_uid(ics_data)
                    success = push_to_radicale(uid, ics_data)
                    if not success:
                        all_succeeded = False
                        log.error(f"Failed to push UID {uid} to Radicale. Email will not be deleted.")

                # Only delete the email and log it if all attachments succeeded
                if all_succeeded:
                    client.delete_messages([msg_id])
                    client.expunge()
                    log_processed(message_id_header)
                    processed_ids.add(message_id_header)
                    log.info(f"Deleted message {message_id_header} and recorded in log.")

    except Exception as e:
        log.error(f"Unexpected error: {e}")
        sys.exit(1)

    log.info("Sync complete.")


if __name__ == "__main__":
    main()
