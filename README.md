# TLS Certificate Auto-Renewal

Automatic TLS certificate issuance and renewal for services hosted on the Raspberry Pi 5 (`pi5`), using [Let's Encrypt](https://letsencrypt.org) via DNS-01 challenge.

The main domain `kuehl.one` is managed at **Strato** (no DNS API). Certificate automation is achieved via **DNS alias mode**: Strato has static CNAME records pointing each `_acme-challenge` entry to a deSEC subdomain (`klarwasser.dedyn.io`), which has a full DNS API. [acme.sh](https://github.com/acmesh-official/acme.sh) uses the deSEC API to set the TXT record there, Let's Encrypt validates it, and the certificate is issued — without ever touching Strato again.

```
Let's Encrypt queries:   _acme-challenge.adguard.kuehl.one
Strato answers:          → CNAME to _acme-challenge.klarwasser.dedyn.io   (set once, never touched again)
acme.sh sets:            TXT record at deSEC via API                       (automatic)
Let's Encrypt:           ✓ validated — certificate issued
```

## Certificates Covered

The single certificate covers the following SANs:

- `kuehl.one`
- `adguard.kuehl.one`
- `paperless.kuehl.one`
- `homeassistant.kuehl.one`

Certificates are stored under `/tools/certs/` on the host and mounted read-only into the relevant Docker containers at `/etc/letsencrypt`.

## How It Works

Renewal is handled by a **Docker container** running the official [neilpang/acme.sh](https://hub.docker.com/r/neilpang/acme.sh) image. The container is launched by a **systemd service** (`acme-renew.service`) triggered on a schedule by a **systemd timer** (`acme-renew.timer`).

```
acme-renew.timer
    → triggers acme-renew.service
        → runs /tools/tls-renewer/renew_service.sh
            → docker run neilpang/acme.sh --issue ...
                → deSEC API sets _acme-challenge TXT
                → Let's Encrypt validates → issues cert
                → cert written to /tools/certs/
```

acme.sh skips renewal if the certificate is not yet within 30 days of expiry (exit code 2, treated as success by systemd via `SuccessExitStatus=0 2`).

## Files

```
/tools/tls-renewer/
├── renew_service.sh          # Docker run command for certificate issuance/renewal
/etc/systemd/system/
├── acme-renew.service        # Systemd service unit
├── acme-renew.timer          # Systemd timer unit
/tools/certs/
└── kuehl.one/                # Issued certificates (acme.sh format)
    ├── kuehl.one.key
    ├── kuehl.one.cer
    ├── fullchain.cer
    └── ...
```

## Setup

### 1. Prerequisites

- Docker installed and running on the Pi
- A [deSEC.io](https://desec.io) account with the domain `klarwasser.dedyn.io` registered
- A deSEC API token with **Manage DNS records** permission

### 2. CNAME Records at Strato

Add these CNAME records once in the Strato DNS management panel. They never need to be changed again.

| Name | Type | Value |
|------|------|-------|
| `_acme-challenge.kuehl.one` | CNAME | `_acme-challenge.klarwasser.dedyn.io` |
| `_acme-challenge.adguard` | CNAME | `_acme-challenge.klarwasser.dedyn.io` |
| `_acme-challenge.paperless` | CNAME | `_acme-challenge.klarwasser.dedyn.io` |
| `_acme-challenge.homeassistant` | CNAME | `_acme-challenge.klarwasser.dedyn.io` |

Verify propagation before proceeding:
```bash
dig _acme-challenge.adguard.kuehl.one CNAME +short
# Expected: _acme-challenge.klarwasser.dedyn.io.
```

### 3. Initial Certificate Issuance

Run this once manually to issue the first certificate:

```bash
docker run --rm \
  -v /tools/certs:/acme.sh \
  -e DEDYN_TOKEN=your_desec_token_here \
  neilpang/acme.sh --issue \
    --server letsencrypt \
    --dns dns_desec \
    --challenge-alias klarwasser.dedyn.io \
    -d kuehl.one \
    -d adguard.kuehl.one \
    -d paperless.kuehl.one \
    -d homeassistant.kuehl.one
```

acme.sh saves the renewal configuration to `/tools/certs/kuehl.one/`. Subsequent runs use these saved parameters automatically.

### 4. renew_service.sh

`/tools/tls-renewer/renew_service.sh` contains the same Docker command (with the real token) and is called by the systemd service:

```bash
#!/bin/bash
docker run --rm \
  -v /tools/certs:/acme.sh \
  -e DEDYN_TOKEN=your_desec_token_here \
  neilpang/acme.sh --issue \
    --server letsencrypt \
    --dns dns_desec \
    --challenge-alias klarwasser.dedyn.io \
    -d kuehl.one \
    -d adguard.kuehl.one \
    -d paperless.kuehl.one \
    -d homeassistant.kuehl.one
```

Make it executable:
```bash
chmod +x /tools/tls-renewer/renew_service.sh
```

### 5. Systemd Service

`/etc/systemd/system/acme-renew.service`:

```ini
[Unit]
Description=Renew ACME certificates (acme.sh)
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
User=toto
ExecStart=/bin/bash /tools/tls-renewer/renew_service.sh
SuccessExitStatus=0 2
StandardOutput=journal
StandardError=journal
SyslogIdentifier=acme-renew
```

### 6. Systemd Timer

`/etc/systemd/system/acme-renew.timer`:

```ini
[Unit]
Description=Run ACME certificate renewal twice daily

[Timer]
OnCalendar=*-*-* 04,16:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable and start:
```bash
systemctl daemon-reload
systemctl enable --now acme-renew.timer
```

## Operations

### Check timer status
```bash
systemctl status acme-renew.timer
systemctl list-timers acme-renew.timer
```

### Run renewal manually
```bash
systemctl start acme-renew.service
```

### View logs
```bash
journalctl -xeu acme-renew.service
```

### Force renewal (ignoring expiry date)
```bash
docker run --rm \
  -v /tools/certs:/acme.sh \
  -e DEDYN_TOKEN=your_desec_token_here \
  neilpang/acme.sh --issue --force \
    --server letsencrypt \
    --dns dns_desec \
    --challenge-alias klarwasser.dedyn.io \
    -d kuehl.one \
    -d adguard.kuehl.one \
    -d paperless.kuehl.one \
    -d homeassistant.kuehl.one
```

### Check certificate expiry
```bash
docker run --rm \
  -v /tools/certs:/acme.sh \
  neilpang/acme.sh --list
```

## Container Mounts

All containers that need TLS mount `/tools/certs` read-only:

```yaml
volumes:
  - /tools/certs:/etc/letsencrypt:ro
```
