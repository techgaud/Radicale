# radicale-selfhost

A set of scripts to deploy a self-hosted CalDAV server (Radicale) with automatic email-to-calendar ingestion, accessible via a public subdomain without exposing any ports on your router.

---

## What This Does

- Deploys Radicale in Docker for calendar sync
- Deploys AgenDAV in Docker as a web calendar interface
- Creates a Cloudflare Tunnel so the server is reachable at a public subdomain — no port forwarding, no exposed home IP
- Automates DNS configuration via the Cloudflare API
- Receives calendar invites via email and automatically pushes them into Radicale using a Cloudflare Email Worker pipeline
- Publishes the project to a new GitHub repository

---

## How It Works

### Tunnel

Cloudflare Tunnel runs as a sidecar container alongside Radicale and AgenDAV. It establishes an outbound connection to Cloudflare's edge network, which maps your chosen subdomains to those services. No inbound firewall rules or port forwarding are required.

### Email Ingest Pipeline

```
Your email provider
  → auto-forward rules (one per calendar address)
    → calendar-specific addresses on your domain
      → Cloudflare Email Routing
        → Email Worker (JavaScript)
          → POST raw email to ingest endpoint
            → ingest.py extracts .ics attachment
              → CalDAV PUT to correct Radicale collection
```

Each calendar gets its own email address. The Worker passes the destination address in the POST. `ingest.py` maps address to collection using `CALENDAR_MAP` in `config.env`. Adding a new calendar requires no code changes — run `provision-calendar.sh` and it handles everything.

---

## Prerequisites

- Ubuntu 22.04
- A domain registered with Namecheap
- A Cloudflare account (free plan is sufficient)
- A GitHub account
- An email provider that supports auto-forwarding (e.g. Proton Mail)

---

## Setup

Run these steps in order.

### 1. Install dependencies

```bash
chmod +x check-deps.sh
./check-deps.sh
```

If Docker was just installed, log out and back in before continuing, or run:

```bash
newgrp docker
```

### 2. Configure

```bash
cp config.env.example config.env
```

Fill in all values. Every field has a comment explaining what it expects. See the **Credentials** section below for where to find each one.

### 3. Run the main setup

```bash
chmod +x setup.sh
./setup.sh
```

This will:
- Add your domain to Cloudflare and retrieve the assigned nameservers
- Pause and give you a link to your Namecheap domain management page with the exact values to enter
- Poll until the zone becomes active
- Create a Cloudflare Tunnel
- Create the DNS record for your subdomain
- Write all config files and start the Docker stack

### 4. Set up Email Routing

```bash
chmod +x cloudflare-setup.sh
./cloudflare-setup.sh
```

This deploys the Email Worker to Cloudflare, sets its secrets, and creates routing rules for every address in your `CALENDAR_MAP`.

Then run the Docker stack to start the ingest service:

```bash
docker compose up -d --force-recreate
```

### 5. Set up auto-forward in your email provider

For each address in your `CALENDAR_MAP`, create an auto-forward rule in your email provider that forwards matching emails to that address. This step is always manual since email providers do not expose APIs for forward rules.

Test with: `docker logs ingest -f`

### 6. Push to GitHub

```bash
chmod +x github-setup.sh
./github-setup.sh
```

---

## Adding a New Calendar

```bash
./provision-calendar.sh -a newaddress@yourdomain.com -p /youruser/newcalendar/ -t vevent
```

Use `-t vtodo` for a task list instead of a calendar. The script creates the Cloudflare routing rule, the Radicale collection, and updates `CALENDAR_MAP` in `config.env`. Then restart the ingest container and add the Proton forward rule.

---

## Credentials

### Cloudflare Global API Key
`dash.cloudflare.com/profile/api-tokens` → scroll down to "Global API Key" → View

### Cloudflare Zone ID and Account ID
`dash.cloudflare.com` → select your domain → right sidebar

### Cloudflare API Token (for Email Routing + Workers)
`dash.cloudflare.com/profile/api-tokens` → Create Custom Token  
Permissions needed:
- Zone > Email Routing Rules > Edit
- Zone > Zone > Read
- Account > Workers Scripts > Edit

### Ingest Token
Generate with: `openssl rand -hex 32`  
This is a shared secret between the Email Worker and `ingest.py`. Set it in `config.env` and `cloudflare-setup.sh` will push it to the Worker automatically.

### GitHub Tokens
Two tokens are needed — see the comments in `config.env.example` for exact steps.

---

## Connecting DAVx5 on Android

1. Install DAVx5 from F-Droid or the Play Store
2. Tap + → "Login with URL and user name"
3. URL: `https://<SUBDOMAIN>.<DOMAIN>/<RADICALE_USER>/`
4. Username and password: values from `config.env`
5. DAVx5 will discover your calendars automatically

---

## Directory Structure

```
.
├── check-deps.sh              # Installs all required system dependencies
├── setup.sh                   # Cloudflare, DNS, Radicale, and Docker stack setup
├── cloudflare-setup.sh        # Deploys Email Worker and creates routing rules
├── provision-calendar.sh      # Adds a new calendar end-to-end
├── github-setup.sh            # Creates and pushes the GitHub repository
├── ingest.py                  # HTTP server: receives emails, pushes .ics to Radicale
├── commit.sh                  # Stages, commits, and pushes using commit.msg
├── commit.msg.example         # Example commit message showing correct format
├── commit.msg                 # Your active commit message — never committed
├── config.env.example         # Template config — copy to config.env and fill in
├── config.env                 # Your real config — never committed
├── worker/
│   ├── email-worker.js        # Cloudflare Email Worker source
│   └── wrangler.toml          # Worker config
├── agendav-config/            # AgenDAV configuration and entrypoint
├── config/                    # Radicale server config and htpasswd file
├── data/                      # Radicale calendar storage
├── logs/                      # Runtime logs
└── cloudflared-config/
    ├── config.yml             # Cloudflare Tunnel ingress config
    └── creds/                 # Tunnel credential JSON (never committed)
```

---

## What Is and Is Not Committed to Git

Committed:
- All scripts and source files
- `config.env.example`
- Directory structure placeholders (`.gitkeep` files)

Never committed:
- `config.env` — contains real credentials
- `commit.msg` — your active commit message, often mid-edit
- `config/users` — contains hashed passwords
- `cloudflared-config/creds/` — contains tunnel credentials (treat like a private key)
- `data/` — contains your calendar data
- `logs/*.log` — runtime logs
- `worker/.wrangler/` — Wrangler cache, contains account metadata

---

## Making Changes and Committing

Write your message in `commit.msg` and run `commit.sh`. The format is standard two-part git:

```
Short summary under 50 characters

Body explaining what changed and why, wrapped at 72 characters.
```

`commit.msg` is cleared automatically after a successful push. See `commit.msg.example` for the format.

---

## License

This project is licensed under the GNU Affero General Public License v3.0. See the LICENSE file for details.
