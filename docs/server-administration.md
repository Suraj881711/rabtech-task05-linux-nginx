# Server Administration Documentation — Task 05

**Linux Server Administration & Nginx Reverse Proxy**
RabTech Academy Internship (Cloud Computing & DevOps) — Suraj Dhakad

This document explains every administrative step performed by
[`../setup-server.sh`](../setup-server.sh) and how each line of the Nginx
configuration in [`../nginx/`](../nginx/) maps to a requirement of the brief.

---

## 1. System overview

| Item            | Value                                             |
|-----------------|---------------------------------------------------|
| OS              | Ubuntu 22.04 / 24.04 LTS (Debian family)          |
| Admin user      | `deploy` (sudo group, key-only SSH)               |
| Web server      | Nginx (reverse proxy + TLS termination)           |
| Application     | Local service on `127.0.0.1:8000` (loopback only)|
| Public ports    | 22 (SSH), 80 (HTTP), 443 (HTTPS) — nothing else   |
| TLS             | Let's Encrypt via Certbot (self-signed in sandbox)|

```
Internet ──► UFW (22/80/443 only) ──► Nginx :443 (TLS termination)
                                          │  reverse proxy, gzip,
                                          │  rate limit, cache headers
                                          ▼
                                   App on 127.0.0.1:8000
                                   (never exposed publicly)
```

The application port (8000) is bound to loopback, so the *only* way in from
the internet is through Nginx — that is the point of the firewall rules below.

---

## 2. User and permission model

| Account   | Shell       | Groups | Password login | Purpose                          |
|-----------|-------------|--------|----------------|----------------------------------|
| `root`    | —           | —      | **Disabled** (SSH) | Never used for remote access |
| `deploy`  | `/bin/bash` | `sudo` | **Disabled** (key-only) | Day-to-day administration |
| `www-data`| `nologin`   | —      | n/a            | Runs the Nginx workers           |

Steps performed by the script:

```bash
useradd --create-home --shell /bin/bash deploy
usermod --append --groups sudo deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
# public key appended to /home/deploy/.ssh/authorized_keys (mode 600)
```

Permission principles applied:

- `~/.ssh` is `700`, `authorized_keys` is `600` — SSH refuses keys from
  loosely-permissioned files, and other users cannot read them.
- Administration happens through `sudo` from `deploy`, giving an audit trail
  in `/var/log/auth.log` instead of anonymous root sessions.
- The script is idempotent-ish: it checks `id deploy` and searches
  `authorized_keys` before adding anything, so re-runs change nothing.

---

## 3. SSH hardening

Configuration is delivered as a **drop-in** file so the vendor's main
`sshd_config` stays untouched:

`/etc/ssh/sshd_config.d/99-hardening.conf`

```
PasswordAuthentication no          # password-based SSH is DISABLED
ChallengeResponseAuthentication no # no keyboard-interactive fallback
PubkeyAuthentication yes           # public-key auth only
PermitRootLogin no                 # root can never log in over SSH
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
```

The script runs `sshd -t` **before** restarting the service, so an invalid
configuration can never lock the administrator out. After hardening:

```bash
$ ssh deploy@server            # works — with the private key
$ ssh root@server              # Permission denied
$ ssh -o PreferredAuthentications=password deploy@server
                               # Permission denied (publickey)
```

---

## 4. Firewall — UFW

Default policy: **deny all incoming, allow all outgoing.** Only three
ports are opened:

| Port | Protocol | Service | Rule                         |
|------|----------|---------|------------------------------|
| 22   | TCP      | SSH     | `ufw allow 22/tcp`           |
| 80   | TCP      | HTTP    | `ufw allow 80/tcp` (redirect to HTTPS + ACME) |
| 443  | TCP      | HTTPS   | `ufw allow 443/tcp`          |
| 8000 | TCP      | App     | **NOT opened** — loopback only |

```bash
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable
```

Expected `ufw status verbose` output:

```
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), disabled (routed)

22/tcp                     ALLOW IN    Anywhere    # SSH
80/tcp                     ALLOW IN    Anywhere    # HTTP
443/tcp                    ALLOW IN    Anywhere    # HTTPS
22/tcp (v6)                ALLOW IN    Anywhere (v6)
80/tcp (v6)                ALLOW IN    Anywhere (v6)
443/tcp (v6)               ALLOW IN    Anywhere (v6)
```

---

## 5. Nginx architecture — requirement → configuration map

### 5.1 Reverse proxy to the local app

`nginx/sites-available/app.conf`:

```nginx
upstream app_backend {
    server 127.0.0.1:8000;
    keepalive 32;
}

location / {
    proxy_pass http://app_backend;
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

TLS is terminated at Nginx, so the backend speaks plain HTTP on loopback
and never handles certificates itself.

### 5.2 HTTP → HTTPS redirect

The port-80 server block returns `301 https://$host$request_uri` for every
request except `/.well-known/acme-challenge/`, which Certbot needs for
HTTP-01 domain validation and renewals.

### 5.3 Gzip compression

In `nginx/nginx.conf` (http context, so it applies to all vhosts):

```nginx
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 6;
gzip_min_length 1024;
gzip_types text/plain text/css application/json application/javascript
           image/svg+xml; # (full list in the file)
```

### 5.4 Caching headers

- `proxy_cache_path ... keys_zone=app_cache:10m` declares a 1 GB on-disk
  cache in `/var/cache/nginx/app_cache`.
- `location /static/` uses that cache (`proxy_cache_valid 200 ... 7d`) and
  sends browsers `Cache-Control: public, max-age=2592000, immutable` with
  `expires 30d` — fingerprinted static files are cached hard.
- `location /` sends `Cache-Control: no-store` and `proxy_no_cache 1` —
  dynamic application responses are never shared-cached.

### 5.5 Rate limiting

Zone declared once in `nginx.conf`:

```nginx
limit_req_zone $binary_remote_addr zone=app_limit:10m rate=10r/s;
```

Applied per-location in `app.conf`:

```nginx
location / {
    limit_req zone=app_limit burst=20 nodelay;   # 10 r/s sustained, burst 20
}
```

Excess requests receive **HTTP 429**. The `/health` location deliberately
has no limit so monitoring is never throttled.

### 5.6 Security headers

Sent on every response (`always`, so they also appear on error pages):

| Header | Value |
|--------|-------|
| `X-Content-Type-Options` | `nosniff` |
| `X-Frame-Options` | `SAMEORIGIN` |
| `Referrer-Policy` | `strict-origin-when-cross-origin` |
| `Strict-Transport-Security` | `max-age=31536000; includeSubDomains` |

Note: Nginx `add_header` in a location block *replaces* server-level
headers, so the headers are repeated inside `/static/` and `/` — this is
intentional and commented in the file.

### 5.7 Logging

| Stream | Path |
|--------|------|
| App access | `/var/log/nginx/app.access.log` |
| App errors | `/var/log/nginx/app.error.log` |
| Global defaults | `/var/log/nginx/access.log`, `/var/log/nginx/error.log` |

---

## 6. SSL/TLS

### 6.1 Let's Encrypt with Certbot (production path)

```bash
apt-get install -y certbot
certbot certonly --webroot -w /var/www/certbot \
    -d example.com -d www.example.com \
    --email admin@example.com --agree-tos
systemctl reload nginx
```

Certificates land in `/etc/letsencrypt/live/example.com/` — exactly the
paths referenced by `ssl_certificate` in `app.conf`. Renewal is automatic
via the `certbot.timer` systemd unit shipped with the package; the port-80
ACME location keeps HTTP-01 validation working after the redirect is live.
Settings in `app.conf` restrict protocols to **TLS 1.2 / 1.3** and enable
session caching with tickets off.

### 6.2 Self-signed alternative (sandbox / lab)

When no public domain exists, generate a local pair and point the vhost at
it instead (the commented block at the end of `setup-server.sh` does this):

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/app.key \
    -out    /etc/nginx/ssl/app.crt \
    -subj "/CN=example.com"
```

Browsers will warn about the unknown issuer — expected and acceptable in a
sandbox; the TLS mechanics (termination, protocols, headers) are identical.

---

## 7. Verification — commands and expected results

Run these after `setup-server.sh` to prove every requirement:

```bash
# 1. Configuration is valid
$ nginx -t
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful

# 2. Only 22/80/443 are listening publicly; 8000 is loopback-only
$ ss -tulpn | grep -E ':(22|80|443|8000)'
tcp  LISTEN  0.0.0.0:22        (sshd)
tcp  LISTEN  0.0.0.0:80        (nginx)
tcp  LISTEN  0.0.0.0:443       (nginx)
tcp  LISTEN  127.0.0.1:8000    (app)

# 3. Firewall state
$ sudo ufw status verbose        # see the table in section 4

# 4. HTTP redirects to HTTPS
$ curl -I http://example.com
HTTP/1.1 301 Moved Permanently
Location: https://example.com/

# 5. HTTPS works, headers + gzip are present
$ curl -I https://example.com
HTTP/2 200
x-content-type-options: nosniff
x-frame-options: SAMEORIGIN
referrer-policy: strict-origin-when-cross-origin
strict-transport-security: max-age=31536000; includeSubDomains

$ curl -s -H 'Accept-Encoding: gzip' -I https://example.com | grep -i encoding
content-encoding: gzip

# 6. Rate limiting — the 31st rapid request onward returns 429
$ for i in $(seq 1 35); do curl -s -o /dev/null -w '%{http_code}\n' https://example.com/; done | sort | uniq -c
    30 200
     5 429

# 7. SSH password login is refused
$ ssh -o PreferredAuthentications=password deploy@server
Permission denied (publickey).
```

---

## 8. Operations cheat-sheet

| Action | Command |
|--------|---------|
| Test config before reload | `sudo nginx -t` |
| Reload Nginx | `sudo systemctl reload nginx` |
| Tail app access log | `sudo tail -f /var/log/nginx/app.access.log` |
| Firewall rules | `sudo ufw status numbered` |
| Add a temporary rule | `sudo ufw allow <port>/tcp` (then delete: `sudo ufw delete allow <port>/tcp`) |
| Check certificate expiry | `sudo certbot certificates` |
| Renew certificates (dry run) | `sudo certbot renew --dry-run` |
