# radicale-selfhost

A set of scripts to deploy a self-hosted Radicale CalDAV/CardDAV server, accessible via a public subdomain, without exposing any ports on your router. Uses Cloudflare Tunnel to handle ingress, so your home IP address is never exposed and dynamic IP is not a concern.

---

## What This Does

- Deploys Radicale in Docker for calendar and contact sync
- Creates a Cloudflare Tunnel so the server is reachable at a public subdomain
- Automates DNS configuration at both Cloudflare and Namecheap
- Publishes the project to a new GitHub repository

---

## How It Works

Cloudflare Tunnel runs as a sidecar container alongside Radicale. It establishes an outbound connection to Cloudflare's edge network, which maps your chosen subdomain to that tunnel. No inbound firewall rules or port forwarding are required. Your server's IP address is never exposed.

---

## Prerequisites

- Ubuntu 22.04
- A domain registered with Namecheap
- A Cloudflare account (free plan is sufficient)
- A GitHub account

---

## One-Time Manual Steps

These two things cannot be scripted and must be done by hand before running anything.

### Cloudflare Global API Key

1. Log in to Cloudflare
2. Go to https://dash.cloudflare.com/profile/api-tokens
3. Scroll down to "Global API Key" and click "View"
4. Copy the key

### GitHub Personal Access Token

1. Go to https://github.com/settings/tokens
2. Click "Generate new token (classic)"
3. Give it a name, set a short expiration (7 days is enough)
4. Check the "repo" scope
5. Click "Generate token" and copy it

---

## Setup

Run these steps in order. Do not skip ahead — each step depends on the previous one being complete.

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

Copy the example config and fill in your values:

```bash
cp config.env.example config.env
```

Open `config.env` in your editor. Every field has a comment explaining what it expects. Fill in all values before proceeding. This includes the Cloudflare, Radicale, Proton, and GitHub sections. The `BRIDGE_IMAP_PORT` and `BRIDGE_IMAP_PASS` fields will be filled in automatically by `bridge-setup.sh` — leave them as-is for now.

### 3. Run the main setup

```bash
chmod +x setup.sh
./setup.sh
```

This will:

- Add your domain to Cloudflare and retrieve the assigned nameservers
- Pause and give you a clickable link to your Namecheap domain management page with the exact nameserver values to enter
- Poll until the Cloudflare zone becomes active after you save the change (can take minutes to a few hours)
- Create a Cloudflare Tunnel
- Create the DNS record for your subdomain
- Write all config files
- Create your Radicale user
- Start the Docker stack

### 4. Set up Proton Bridge and ICS sync

```bash
chmod +x bridge-setup.sh
./bridge-setup.sh
```

This handles the one-time Bridge login interactively and sets up everything needed for automatic ICS sync. See the ICS Sync section below for full details on what this does and what to expect during the login step.

### 5. Push to GitHub

```bash
chmod +x github-setup.sh
./github-setup.sh
```

This creates the repository, initialises git, and pushes everything except your credentials and data. Run this after `bridge-setup.sh` so that the `BRIDGE_IMAP_PORT` and `BRIDGE_IMAP_PASS` values written back to `config.env` are not accidentally staged — they are already covered by the `.gitignore`.

---

## ICS Sync from Proton Mail

This project includes an automated pipeline that watches a folder in your Proton Mail account and pushes any .ics attachments it finds directly into Radicale. The intended workflow is: receive a calendar invite anywhere in your inbox, move the email to your designated sync folder, and within a few seconds the event appears in your calendar with no further action required.

### Prerequisites

- A paid Proton Mail plan (required for Bridge)
- Proton Bridge installed (handled by `check-deps.sh`)

### How it works

Proton Bridge runs as a background service and exposes a local IMAP interface on localhost that decrypts your Proton Mail on the fly. `goimapnotify` holds an IMAP IDLE connection open against that interface, watching only the folder you specify. The moment new mail arrives in that folder, goimapnotify fires `ics-sync.py`. The script extracts any .ics attachments, pushes each one to Radicale via a CalDAV PUT request, deletes the email from the folder, and records the Message-ID in a log file to prevent duplicate processing.

No polling is involved. The sync fires on arrival.

### One-time manual steps required before running bridge-setup.sh

Bridge requires a secret-service compatible password manager on Linux. This project uses `pass`, which is installed by `check-deps.sh`. `pass` requires a GPG key, which `bridge-setup.sh` generates automatically using the passphrase you set in `config.env`.

The one thing that cannot be scripted is the initial Bridge login, which requires your Proton Mail password and a 2FA TOTP code entered interactively.

### Setup

Run `bridge-setup.sh` after `check-deps.sh` and after filling in the Proton-related fields in `config.env`:

```bash
chmod +x bridge-setup.sh
./bridge-setup.sh
```

The script will:

1. Generate a GPG key using your `GPG_PASSPHRASE` and initialise `pass`
2. Configure `gpg-agent` to cache the passphrase so Bridge runs unattended
3. Start Bridge in CLI mode for the one-time interactive login
4. List every available IMAP folder from Bridge so you can confirm the exact folder name to watch
5. Save the confirmed folder name, IMAP port, and Bridge-generated IMAP password back to `config.env`
6. Register Bridge as a systemd user service so it starts at boot
7. Write the goimapnotify config pointing at your chosen folder
8. Register goimapnotify as a systemd user service

### Confirming the watched folder name

During step 4, the script will print a list of every folder Bridge can see in your Proton Mail account, for example:

```
    Available folders:
      INBOX
      Drafts
      Sent
      Spam
      Trash
      CalendarImport
```

The folder name must match exactly, including capitalisation. If the folder you want does not appear in the list, create it in Proton Mail first and then re-run `bridge-setup.sh`.

### Checking service status

```bash
systemctl --user status proton-bridge
systemctl --user status goimapnotify
```

### The sync log

Every successfully processed email has its Message-ID recorded in the file set by `ICS_SYNC_LOG` in `config.env`. The default path is `./logs/ics-sync.log` inside the project directory. Each line contains a UTC timestamp and the Message-ID:

```
2024-01-15 09:32:11  <CABx3+abc123@mail.gmail.com>
```

This log is the source of truth for deduplication. If an email is processed but the CalDAV PUT fails, it is not logged, and the next sync attempt will retry it. The log file is never committed to git.

---

## Connecting DAVx5 on Android

1. Install DAVx5 from F-Droid or the Play Store
2. Tap + and select "Login with URL and user name"
3. Enter the following:
   - URL: `https://<SUBDOMAIN>.<DOMAIN>/<RADICALE_USER>/`
   - Username: the value of `RADICALE_USER` from your config
   - Password: the value of `RADICALE_PASS` from your config
4. DAVx5 will discover your address books and calendars automatically
5. Select which collections to sync and tap the sync button

For calendar display on Android, any app that reads local calendar accounts will work. Etar and Simple Calendar are both solid options.

---

## Directory Structure

```
.
├── check-deps.sh              # Installs all required system dependencies
├── setup.sh                   # Cloudflare, DNS, Radicale, and Docker stack setup
├── bridge-setup.sh            # Proton Bridge, GPG, pass, and goimapnotify setup
├── ics-sync.py                # Fired by goimapnotify, pushes .ics files to Radicale
├── github-setup.sh            # Creates and pushes the GitHub repository
├── commit.sh                  # Stages, commits, and pushes using commit.msg
├── commit.msg.example         # Example commit message showing correct format
├── commit.msg                 # Your active commit message — never committed
├── config.env.example         # Template config — copy to config.env and fill in
├── config.env                 # Your real config — never committed
├── config/
│   ├── config                 # Radicale server config (generated by setup.sh)
│   └── users                  # Radicale htpasswd file (generated by setup.sh)
├── data/                      # Radicale calendar and contact storage
├── logs/
│   └── ics-sync.log           # ICS sync processing log (generated at runtime)
├── cloudflared-config/
│   ├── config.yml             # Cloudflare Tunnel ingress config (generated by setup.sh)
│   └── creds/                 # Tunnel credential JSON (generated by setup.sh)
└── docker-compose.yml         # Docker Compose config (generated by setup.sh)
```

---

## What Is and Is Not Committed to Git

The repository contains everything needed to reproduce a fresh deployment. It does not contain anything specific to your instance.

Committed:
- All scripts
- `config.env.example`
- Directory structure placeholders

Never committed:
- `config.env` — contains real credentials
- `commit.msg` — your active commit message, often mid-edit
- `config/users` — contains hashed passwords
- `cloudflared-config/creds/` — contains tunnel credentials
- `data/` — contains your calendar and contact data
- `logs/ics-sync.log` — runtime log, specific to your instance

---

## Making Changes and Committing

This project includes a simple commit workflow that keeps things consistent. Rather than typing commit messages on the command line, you write your message in `commit.msg` and run `commit.sh`.

### The commit message file

Copy the example file to get started:

```bash
cp commit.msg.example commit.msg
```

`commit.msg` follows the standard two-part git format:

```
Short summary of the change, 50 characters or less

Longer description explaining what changed and why. Wrap lines at
72 characters. You can have multiple paragraphs separated by blank
lines if the change warrants it.
```

Lines beginning with `#` are comments and are ignored by git. The file ships with a comment block explaining the format — just write your message above or below the comments.

### Running the commit script

```bash
./commit.sh
```

The script will:

1. Read `commit.msg` and strip comments
2. Validate that the message is not empty
3. Warn if the subject line exceeds 50 characters (but will not block)
4. Stage all changes
5. Show you exactly which files are being committed
6. Commit using the message from `commit.msg`
7. Push to the remote
8. Clear `commit.msg` back to the comment block only, ready for next use

### Important clearing behaviour

The file is only cleared after a successful commit and push. If either step fails, `commit.msg` is left untouched so you do not lose your message. Once cleared, the file remains present in the working tree so git never sees a deletion — it just contains the comment block with no active message.

---

## License

This project is licensed under the GNU Affero General Public License v3.0. See the LICENSE file for details.
