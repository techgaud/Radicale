#!/usr/bin/env python3

# ─────────────────────────────────────────────────────────────────────────────
# delete-test-events.py
#
# Removes test events (UID starting with "test-") from the Radicale calendar.
# Reads config.env for credentials and calendar URL.
# ─────────────────────────────────────────────────────────────────────────────

import sys
import urllib.request
import urllib.error
import urllib.parse
import base64
import re
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
CONFIG_FILE = SCRIPT_DIR / "config.env"

if not CONFIG_FILE.exists():
    print(f"ERROR: config.env not found at {CONFIG_FILE}")
    sys.exit(1)

config = {}
with open(CONFIG_FILE) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, raw_value = line.partition("=")
        key = key.strip()
        value = raw_value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
            value = value[1:-1]
        config[key] = value

RADICALE_URL = config["RADICALE_CALENDAR_URL"].rstrip("/") + "/"
RADICALE_USER = config["RADICALE_USER"]
RADICALE_PASS = config["RADICALE_PASS"]

credentials = base64.b64encode(f"{RADICALE_USER}:{RADICALE_PASS}".encode()).decode()
headers = {
    "Authorization": f"Basic {credentials}",
    "User-Agent": "ics-sync/1.0",
}

# ─────────────────────────────────────────────────────────────────────────────
# LIST EVENTS VIA PROPFIND
# ─────────────────────────────────────────────────────────────────────────────
propfind_body = """<?xml version="1.0" encoding="UTF-8"?>
<propfind xmlns="DAV:">
  <prop><getetag/></prop>
</propfind>""".encode()

req = urllib.request.Request(
    RADICALE_URL,
    data=propfind_body,
    method="PROPFIND",
    headers={**headers, "Content-Type": "application/xml", "Depth": "1"},
)

try:
    with urllib.request.urlopen(req) as resp:
        body = resp.read().decode()
except urllib.error.HTTPError as e:
    print(f"ERROR: PROPFIND failed: HTTP {e.code}")
    sys.exit(1)

# Extract .ics hrefs from the PROPFIND response
hrefs = re.findall(r"<(?:D:|d:|DAV:)?href>([^<]*\.ics)</(?:D:|d:|DAV:)?href>", body)

if not hrefs:
    print("No .ics events found in calendar.")
    sys.exit(0)

# ─────────────────────────────────────────────────────────────────────────────
# FIND AND DELETE TEST EVENTS
# ─────────────────────────────────────────────────────────────────────────────
deleted = 0
for href in hrefs:
    filename = href.rsplit("/", 1)[-1]
    decoded = urllib.parse.unquote(filename).replace(".ics", "")

    if not decoded.startswith("test-"):
        continue

    url = urllib.request.urljoin(RADICALE_URL, href)
    del_req = urllib.request.Request(url, method="DELETE", headers=headers)

    try:
        with urllib.request.urlopen(del_req) as resp:
            print(f"Deleted: {decoded}")
            deleted += 1
    except urllib.error.HTTPError as e:
        print(f"Failed to delete {decoded}: HTTP {e.code}")

print(f"\nDone. Deleted {deleted} test event(s).")
