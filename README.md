# TLS Certificates (acme.sh + deSEC)

This repository contains all configuration and scripts needed to automatically obtain and renew TLS certificates for:

- `adguard.kuehl.one`
- `paperless.kuehl.one`
- `homeassistant.kuehl.one`
- (optionally) more `*.kuehl.one` services like `pms.kuehl.one`

Certificates are issued by Let’s Encrypt using `acme.sh` with DNS‑01 challenges via deSEC in **DNS alias mode**, because Strato’s DNS has no API.

The resulting certificates are installed into `/etc/letsencrypt/live/kuehl.one/` and used by Caddy and other Docker services via volume mounts.

---

## How the DNS alias mode works

Flow for `adguard.kuehl.one` (analogous for others):

1. Let’s Encrypt asks for a TXT record at  
   `_acme-challenge.adguard.kuehl.one`.
2. Strato DNS responds with a CNAME pointing to  
   `_acme-challenge.klarwasser.dedyn.io` (deSEC domain).
3. `acme.sh` uses the deSEC API to create the TXT record at  
   `_acme-challenge.klarwasser.dedyn.io`.
4. Let’s Encrypt follows the CNAME, finds the TXT at deSEC, validates, and issues the cert.

Strato is only used for the static CNAMEs once; everything dynamic happens via deSEC and `acme.sh`.

---

## Directory layout (on the Pi)

Example when cloning this repo to `~/github/tls`:

- `~/github/tls/`
  - `acme-env.sh`  
    Exports deSEC credentials and convenience variables.
  - `issue-cert.sh`  
    One‑shot script to issue/renew the certificate manually.
  - `systemd/`
    - `acme-renew.service`
    - `acme-renew.timer`  
    User‑level systemd units for automated renewal and reload.
  - `README.md` (this file)

Outside the repo (on the system):

- `~/.acme.sh/` – acme.sh installation and cached certs.
- `/etc/letsencrypt/live/kuehl.one/` – final certs used by Docker containers (mounted read‑only).

---

## Step 1: Prepare deSEC

1. Go to [https://desec.io](https://desec.io) and create an account.  
2. Register a domain or use your existing `klarwasser.dedyn.io` (already used in your setup).
3. In deSEC’s web UI, create an **API token** with permission to manage DNS records.

Keep the token ready; it will be stored in a local env file on the Pi, not in Git.

---

## Step 2: Configure CNAMEs at Strato

In Strato’s DNS panel for `kuehl.one`, create these CNAME records:

| Name (Host)                | Type  | Value                                     |
|----------------------------|-------|-------------------------------------------|
| `_acme-challenge.adguard`  | CNAME | `_acme-challenge.klarwasser.dedyn.io.`    |
| `_acme-challenge.paperless`| CNAME | `_acme-challenge.klarwasser.dedyn.io.`    |
| `_acme-challenge.homeassistant` | CNAME | `_acme-challenge.klarwasser.dedyn.io.` |

Notes:

- In Strato’s UI, you typically enter just the prefix (e.g. `_acme-challenge.adguard`), and Strato appends `.kuehl.one` automatically.
- The trailing dot in the FQDN may or may not be required by the UI; Strato often appends it automatically.

Check later with `dig`:

```bash
dig @1.1.1.1 _acme-challenge.adguard.kuehl.one CNAME +short
dig @1.1.1.1 _acme-challenge.paperless.kuehl.one CNAME +short
dig @1.1.1.1 _acme-challenge.homeassistant.kuehl.one CNAME +short
```

Each should resolve to `_acme-challenge.klarwasser.dedyn.io.` before you issue the cert.

---

## Step 3: Install acme.sh (user `toto`)

On the Pi, as user `toto`:

```bash
curl https://get.acme.sh | sh
```

This installs `acme.sh` into `~/.acme.sh/` and sets up a `cron` entry for automatic renewal.

Optionally, configure the default CA and notification email if you want.

---

## Step 4: Create `acme-env.sh` for deSEC

In `~/github/tls/acme-env.sh`:

```bash
#!/usr/bin/env bash

# deSEC API token (do NOT commit real value)
export DESEC_TOKEN="CHANGEME_DESEC_TOKEN"

# Common settings
export ACME_SERVER="letsencrypt"
export ACME_ALIAS_DOMAIN="klarwasser.dedyn.io"

# Domains
export ACME_DOMAINS=" \
  -d adguard.kuehl.one \
  -d paperless.kuehl.one \
  -d homeassistant.kuehl.one \
"

# Optional: add pms.kuehl.one if not covered by a wildcard
# export ACME_DOMAINS="$ACME_DOMAINS -d pms.kuehl.one"
```

Make it non‑world‑readable and executable:

```bash
chmod 600 acme-env.sh
chmod +x acme-env.sh
```

Do **not** commit the real `DESEC_TOKEN` – keep only the `CHANGEME` placeholder in Git.

---

## Step 5: One‑shot issue script

In `~/github/tls/issue-cert.sh`:

```bash
#!/usr/bin/env bash
set -e

# Load deSEC token and common vars
. "$(dirname "$0")/acme-env.sh"

# Issue/renew certificate using DNS alias mode with deSEC
~/.acme.sh/acme.sh --issue \
  --server "$ACME_SERVER" \
  --dns dns_desec \
  --challenge-alias "$ACME_ALIAS_DOMAIN" \
  $ACME_DOMAINS

# Install the cert into /etc/letsencrypt/live/kuehl.one/
sudo mkdir -p /etc/letsencrypt/live/kuehl.one

sudo ~/.acme.sh/acme.sh --install-cert \
  -d adguard.kuehl.one \
  --cert-file      /etc/letsencrypt/live/kuehl.one/cert.pem \
  --key-file       /etc/letsencrypt/live/kuehl.one/privkey.pem \
  --fullchain-file /etc/letsencrypt/live/kuehl.one/fullchain.pem \
  --reloadcmd      "docker restart paperless-caddy-1 adguard homeassistant"
```

Adjust the reload command with your actual container names from `docker ps`.

Make the script executable:

```bash
chmod +x issue-cert.sh
```

First manual run (after CNAMEs have propagated):

```bash
cd ~/github/tls
./issue-cert.sh
```

If this completes successfully, your certs should appear under:

```bash
ls -l /etc/letsencrypt/live/kuehl.one/
```

Caddy and other services already mount `/etc/letsencrypt` read‑only via Docker, so they will pick up the new certs.

---

## Step 6: Systemd service and timer for automated renewal

Instead of relying only on cron, you can run `acme.sh --cron` via a systemd user service for better logging.

### 6.1 Create `systemd/acme-renew.service`

In `~/github/tls/systemd/acme-renew.service`:

```ini
[Unit]
Description=acme.sh certificate renewal (deSEC alias mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=toto
Environment=HOME=/home/toto
Environment=LOGNAME=toto
Environment=USER=toto
WorkingDirectory=/home/toto/github/tls
ExecStart=/bin/bash -lc '. ./acme-env.sh && ~/.acme.sh/acme.sh --cron'

[Install]
WantedBy=multi-user.target
```

### 6.2 Create `systemd/acme-renew.timer`

```ini
[Unit]
Description=Run acme.sh renewal daily

[Timer]
OnBootSec=5min
OnUnitActiveSec=24h
Unit=acme-renew.service

[Install]
WantedBy=timers.target
```

### 6.3 Install the units for user `toto`

Copy the files into the user systemd directory:

```bash
mkdir -p ~/.config/systemd/user
cp systemd/acme-renew.service ~/.config/systemd/user/
cp systemd/acme-renew.timer   ~/.config/systemd/user/
```

Reload and enable:

```bash
systemctl --user daemon-reload
systemctl --user enable --now acme-renew.timer
```

Check status:

```bash
systemctl --user status acme-renew.timer
systemctl --user status acme-renew.service
journalctl --user -u acme-renew.service
```

The timer runs `acme.sh --cron` once per day; `acme.sh` itself decides when to actually renew each certificate and will run the `--install-cert` hooks as needed.

---

## Step 7: Using the certificates in Docker (Caddy, etc.)

Your Docker services mount `/etc/letsencrypt` read‑only. Example for Caddy:

```yaml
services:
  caddy:
    image: caddy:alpine
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
```

In the Caddyfile, you can either:

- Let Caddy obtain its own certs via HTTP/TLS‑ALPN challenge, **or**
- Point to the existing certs from `/etc/letsencrypt/live/kuehl.one/` if you prefer full centralization.

Other containers (AdGuard, Home Assistant, Paperless) just need the mounted certs; they do not run ACME themselves.

---

## Rebuild checklist (new Pi or reinstall)

On a new Pi or after OS reinstall:

1. Install Docker, Caddy, and your service stacks as usual.
2. Install `acme.sh` as user `toto`.
3. Clone this repo to `~/github/tls`.
4. Recreate `acme-env.sh` with your deSEC token.
5. Recreate `acme-renew.service` and `.timer` into `~/.config/systemd/user/` and enable the timer.
6. Run `./issue-cert.sh` once to get initial certificates.
7. Verify that Docker services see the certs under `/etc/letsencrypt/live/kuehl.one/` and that HTTPS endpoints (e.g. `https://paperless.kuehl.one`) work.

---

Once you create this repo, the only manual pieces you’ll need to fill are the real `DESEC_TOKEN` and the actual container names in `issue-cert.sh`.
