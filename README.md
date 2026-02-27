# radicale-selfhost

A set of scripts to deploy a self-hosted CalDAV server (Radicale) with automatic email-to-calendar ingestion, accessible via a public subdomain without exposing any ports on your router.

---

## What This Does

- Deploys Radicale in Docker for CalDAV calendar sync
- Deploys AgenDAV in Docker as a web calendar interface
- Creates a Cloudflare Tunnel so all services are reachable at public subdomains — no port forwarding, no exposed home IP
- Automates DNS configuration via the Cloudflare API
- Receives calendar invites forwarded to dedicated email addresses and automatically pushes them into Radicale using a Cloudflare Email Worker pipeline
- Publishes the project to a new GitHub repository

---

## How It Works

### Tunnel

Cloudflare Tunnel runs as a sidecar container. It establishes an outbound connection to Cloudflare's edge network and maps three subdomains to your services. No inbound firewall rules or port forwarding are required. Your home IP is never exposed.

### Email Ingest Pipeline

```
Your email provider
  → auto-forward rules (one per calendar address)
    → calendar-specific addresses on your domain
      → Cloudflare Email Routing
        → Email Worker (JavaScript)
          → POST raw email + destination to ingest endpoint
            → ingest.py maps address to Radicale collection
              → extracts .ics attachment
                → CalDAV PUT to correct collection
```

Each calendar gets its own inbound email address. Adding a new one requires no code changes — run `provision-calendar.sh` and it handles everything.

---

## Prerequisites

- Ubuntu 22.04
- A domain registered with Namecheap
- A Cloudflare account (free plan works)
- A GitHub account
- An email provider that supports auto-forwarding (tested with Proton Mail)

---

## Before You Start

Collect these before running anything. Each is used during setup.

### Cloudflare Global API Key
`dash.cloudflare.com/profile/api-tokens` → scroll to "Global API Key" → View

### Cloudflare Zone ID and Account ID
`dash.cloudflare.com` → select your domain → right sidebar

### Ingest Token
A shared secret between the Email Worker and `ingest.py`.  
Generate one now: `openssl rand -hex 32`

### GitHub Tokens
Two tokens — see the comments in `config.env.example` for exact steps.

---

## Setup

Run these steps in order. Do not skip ahead.

### 1. Install dependencies

```bash
chmod +x check-deps.sh
./check-deps.sh
```

If Docker was just installed, run `newgrp docker` before continuing.

### 2. Configure

```bash
cp config.env.example config.env
```

Fill in every field. Refer to the comments in the file and the **Before You Start** section above.

### 3. Run the main setup

```bash
chmod +x setup.sh
./setup.sh
```

This will:
- Add your domain to Cloudflare and retrieve the assigned nameservers
- Pause and show you exactly which nameservers to enter in Namecheap
- Poll until the zone becomes active (minutes to a few hours)
- Create a permanent scoped `CF_API_TOKEN` and write it to `config.env`
- Create a Cloudflare Tunnel
- Create DNS records for all three subdomains (radicale, calendar, inbound)
- Write all config files: `docker-compose.yml`, `cloudflared-config/config.yml`, `config/config`, `agendav-config/settings.php`
- Create your Radicale user
- Start the Docker stack

When it finishes you should be able to reach Radicale at `https://radicale.yourdomain.com` and AgenDAV at `https://calendar.yourdomain.com`.

### 4. Enable Email Routing in Cloudflare

This step cannot be fully automated. Go to:

`dash.cloudflare.com` → your domain → **Email** → **Email Routing** → **Enable Email Routing**

Complete the wizard. If it requires a destination address to proceed, use your personal email — it will be replaced by Worker rules in the next step.

### 5. Deploy the Email Worker and create routing rules

```bash
chmod +x cloudflare-setup.sh
./cloudflare-setup.sh
```

This deploys the Email Worker to Cloudflare, sets the `INGEST_URL` and `INGEST_TOKEN` secrets on the Worker, and creates Email Routing rules for every address in your `CALENDAR_MAP`.

### 6. Provision your calendars

For each calendar address in your `CALENDAR_MAP`, run:

```bash
./provision-calendar.sh -a youraddress@yourdomain.com -p /youruser/yourcalendar/ -t vevent
```

Use `-t vtodo` for a task list. This creates the Radicale collection and confirms the routing rule. Skip this for addresses that were already in `CALENDAR_MAP` when `cloudflare-setup.sh` ran — those rules already exist.

Then restart the ingest container to pick up the full map:

```bash
docker compose restart ingest
docker logs ingest -f
```

### 7. Set up auto-forward rules in your email provider

For each address in your `CALENDAR_MAP`, create an auto-forward rule in your email provider that forwards relevant incoming emails to that address. Proton Mail: Settings → Filters → Add filter.

Test by forwarding an email with a `.ics` attachment and watching `docker logs ingest -f`.

### 8. Push to GitHub

```bash
chmod +x github-setup.sh
./github-setup.sh
```

---

## Adding a New Calendar Later

```bash
./provision-calendar.sh -a newaddress@yourdomain.com \
                        -p /youruser/newcalendar/ \
                        -t vevent
docker compose restart ingest
```

Then add the auto-forward rule in your email provider. No code changes needed.

---

## Connecting DAVx5 on Android

1. Install DAVx5 from F-Droid or the Play Store
2. Tap + → "Login with URL and user name"
3. URL: `https://radicale.yourdomain.com/youruser/`
4. Username and password: values from `config.env`
5. DAVx5 discovers your calendars automatically

---

## Re-running Setup After Config Changes

If you change values in `config.env` and need to regenerate the stack:

```bash
./setup.sh --force
```

This regenerates all config files and restarts the stack with `--force-recreate`. DNS records and tunnel creation are still idempotent.

---

## Directory Structure

```
.
├── check-deps.sh                  # Installs all required system dependencies
├── setup.sh                       # Main setup: Cloudflare, DNS, Docker stack
├── cloudflare-setup.sh            # Deploys Email Worker, creates routing rules
├── provision-calendar.sh          # Adds a new calendar end-to-end
├── create-subdomain.sh            # Utility: creates a single Cloudflare CNAME
├── github-setup.sh                # Creates and pushes the GitHub repository
├── ingest.py                      # HTTP server: receives emails, pushes .ics to Radicale
├── commit.sh                      # Stages, commits, and pushes using commit.msg
├── commit.msg.example             # Example commit message format
├── commit.msg                     # Active commit message — never committed
├── config.env.example             # Template config — copy to config.env and fill in
├── config.env                     # Your real config — never committed
├── worker/
│   ├── email-worker.js            # Cloudflare Email Worker source
│   └── wrangler.toml              # Worker config
├── agendav-config/
│   ├── settings.php.example       # AgenDAV settings template — edit to change defaults
│   ├── settings.php               # Generated by setup.sh — never committed
│   └── entrypoint.sh             # Container entrypoint: inits DB schema, starts Apache
├── config/
│   ├── config                     # Radicale server config (generated by setup.sh)
│   └── users                      # Radicale htpasswd file (generated by setup.sh)
├── data/                          # Radicale calendar storage — never committed
├── agendav-db/                    # AgenDAV SQLite database — never committed
├── logs/                          # Runtime logs — never committed
└── cloudflared-config/
    ├── config.yml                 # Tunnel ingress config (generated by setup.sh)
    └── creds/                     # Tunnel credential JSON — never committed
```

---

## What Is and Is Not Committed

Committed:
- All scripts and source files
- `config.env.example`, `agendav-config/settings.php.example`
- Directory placeholders (`.gitkeep` files)

Never committed:
- `config.env` — real credentials
- `config/users` — hashed passwords
- `agendav-config/settings.php` — generated from your config
- `cloudflared-config/creds/` — tunnel credentials (treat like a private key)
- `data/`, `agendav-db/`, `logs/` — runtime data
- `worker/.wrangler/` — Wrangler cache

---

## Committing Changes

Write your message in `commit.msg` and run `./commit.sh`. Format:

```
Short summary under 50 characters

Body explaining what changed and why, wrapped at 72 characters.
```

See `commit.msg.example` for the full format. `commit.msg` is cleared automatically after a successful push.

---

## License

GNU Affero General Public License v3.0. See LICENSE for details.
