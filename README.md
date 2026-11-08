# Task 05 — Linux Server Administration & Nginx Reverse Proxy

**RabTech Academy Internship · Cloud Computing & DevOps · Suraj Dhakad**

A hardened Linux server fronted by Nginx acting as a TLS-terminating
reverse proxy for a local application on port **8000**.

## What this repository contains

| Path | Purpose |
|------|---------|
| `nginx/nginx.conf` | Main Nginx config: gzip, proxy cache, rate-limit zone, logging, timeouts. |
| `nginx/sites-available/app.conf` | Virtual host: port 80 → 443 redirect, TLS on 443, reverse proxy, caching headers, rate limiting, security headers. |
| `setup-server.sh` | One-shot, re-runnable bootstrap: deploy user, SSH hardening, UFW firewall, Nginx install/config, Certbot certificate. |
| `docs/server-administration.md` | Full documentation: permission model, firewall table, requirement→config mapping, SSL options, verification commands with expected output. |

## How everything fits together

```
                    ┌────────────────────────────────────────────┐
   Internet ───────►│  UFW firewall                              │
                    │  default deny in · allow 22 / 80 / 443     │
                    └───────────────┬────────────────────────────┘
                                    │
                    ┌───────────────▼────────────────────────────┐
                    │  Nginx                                     │
                    │  :80  → 301 redirect to HTTPS (+ ACME)     │
                    │  :443 → TLS 1.2/1.3 termination            │
                    │         gzip · rate limit 10 r/s (429)     │
                    │         cache headers · security headers   │
                    └───────────────┬────────────────────────────┘
                                    │ proxy_pass (loopback only)
                    ┌───────────────▼────────────────────────────┐
                    │  Application on 127.0.0.1:8000             │
                    │  (not reachable from the internet directly)│
                    └────────────────────────────────────────────┘

   Admin access:  SSH key-only login as user "deploy" (sudo),
                  password authentication and root login disabled.
```

1. **Server administration** — a non-root `deploy` user administers the box
   through `sudo`. SSH is hardened by a drop-in file
   (`PasswordAuthentication no`, `PermitRootLogin no`), and UFW denies all
   incoming traffic except ports **22, 80, 443**.
2. **Reverse proxy** — Nginx terminates TLS on 443 (Let's Encrypt via
   Certbot; a self-signed variant for sandboxes is documented) and proxies
   to the app on `127.0.0.1:8000`, forwarding the real client IP and scheme.
3. **Performance & protection** — gzip for text payloads, a disk-backed
   proxy cache plus long-lived `Cache-Control` for `/static/`, `no-store`
   for dynamic responses, and per-IP rate limiting (10 r/s, burst 20,
   HTTP 429 beyond that). Security headers (`nosniff`, `SAMEORIGIN`,
   `Referrer-Policy`, HSTS) are set on every response.

## Quick start

```bash
# On a fresh Ubuntu server, from a clone of this repository:
sudo bash setup-server.sh
```

Edit the variables at the top of the script first (domain, Certbot email,
and the SSH public key placeholder). The script is safe to re-run: every
step checks before it changes anything.

## Verify

```bash
nginx -t
ss -tulpn | grep -E ':(22|80|443)'     # only these three face the internet
sudo ufw status verbose                # deny incoming; 22/80/443 allowed
curl -I http://example.com             # 301 → https://
curl -I https://example.com            # 200 + security headers
```

Full walkthrough, expected outputs and an operations cheat-sheet:
[`docs/server-administration.md`](docs/server-administration.md).
