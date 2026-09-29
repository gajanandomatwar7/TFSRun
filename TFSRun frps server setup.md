# TFSRun Public Server — Setup Documentation

Documentation for `setup-frps-server.sh`, the single-file deployment of the TFSRun public server.

---

## 1. Overview

TFSRun lets a user expose a VM to the internet under a personal subdomain, with no manual FRP, DNS or TLS configuration:

- **Web apps** are reachable at `https://<app>.tfsrun.cloud`
- **SSH** works with `ssh ssh@<app>.tfsrun.cloud`

`setup-frps-server.sh` is the **entire server-side deployment**. It is uploaded once and run once. It installs and configures everything and also embeds, as heredocs, the two end-user scripts and the Node.js control plane, so nothing else has to be copied to the server.

After it finishes, the whole user-facing surface is three commands:

| # | Where | Command |
|---|-------|---------|
| 1 | Server (once) | `sudo ./setup-frps-server.sh` |
| 2 | Each VM | `curl -fsSL https://tfsrun.cloud/setup-vm.sh \| sudo bash` |
| 3 | Each laptop | `curl -fsSL https://tfsrun.cloud/setup-ssh-client.sh \| sudo bash` |

This is a **one-box reference deployment**: everything runs on one server. `DATABASE_URL` and the other `*_ADDR` values in the generated `.env` can later be split onto separate hosts without changing the VM or client scripts, because those only talk to the public API and DNS names.

---

## 2. Architecture

```
                               INTERNET
                                  │
      ┌───────────────────────────┼───────────────────────────┐
      │ :80/:443                  │ :7000                     │ :5002
      ▼                           ▼                           ▼
 ┌─────────┐               ┌────────────┐              ┌────────────┐
 │  nginx  │               │ frps       │              │ frps       │
 │ (TLS)   │               │ control    │              │ tcpmux     │
 └────┬────┘               │ channel    │              │ HTTP       │
      │                    └─────┬──────┘              │ CONNECT    │
      │                          │ Login hook          └────────────┘
      │                          ▼ (127.0.0.1:8081)     (SSH relay)
      │        ┌──────────────────────────────┐
      ├───────►│ Node.js control plane :8080  │◄──── Postgres :5432
      │ api.*  │  - reserve / credential API  │      (vms table)
      │        │  - frps auth webhook :8081   │
      │        └──────────────────────────────┘
      │
      ├── tfsrun.cloud (apex)  ──► static files: setup-vm.sh, setup-ssh-client.sh, /frp/*.tar.gz
      └── *.tfsrun.cloud       ──► frps vhost HTTP :18080 ──► tunnel ──► VM app
```

### Traffic paths

| Traffic | Path |
|---------|------|
| Install scripts / frp mirror | client → nginx (`tfsrun.cloud`) → static files |
| Control-plane API | VM/laptop → nginx (`api.tfsrun.cloud`) → Node `:8080` |
| App browser traffic | browser → nginx (`*.tfsrun.cloud`) → frps `:18080` → frpc tunnel → VM |
| SSH | `ssh` → `socat` ProxyCommand → frps `:5002` (HTTP CONNECT, routed by hostname) → frpc → VM `:22` |
| Tunnel control channel | frpc on VM → frps `:7000` (TLS enabled on the client) |

frps and the tcpmux port are **not** behind nginx; they carry plain TCP, so nginx has nothing to terminate there.

---

## 3. Prerequisites

**Server**
- Ubuntu/Debian with `apt` (the script uses `apt-get` directly)
- `x86_64` or `aarch64`
- Root access
- Outbound internet access (GitHub, NodeSource, `get.acme.sh`, Let's Encrypt, Hostinger API)

**Domain and DNS** (Hostinger DNS panel), all pointing at the server's public IP:

| Type | Name | Purpose |
|------|------|---------|
| A | `tfsrun.cloud` | Install scripts, frp mirror |
| A | `*.tfsrun.cloud` | App subdomains |
| A | `frps.tfsrun.cloud` | frpc control channel and SSH tcpmux |
| A | `api.tfsrun.cloud` | Control-plane API |

**Credentials**
- A **Hostinger API token** for DNS-01 validation. The script prompts for it, or reads the `HOSTINGER_Token` environment variable.

**VM requirement (not handled by any script):** each VM needs an SSH server listening on port 22 and a Linux user named `ssh`, because the client config uses `User ssh`.

---

## 4. Running the installer

```bash
chmod +x setup-frps-server.sh
sudo ./setup-frps-server.sh
# or, non-interactively for the token:
sudo HOSTINGER_Token=xxxxxxxx ./setup-frps-server.sh
```

The script is designed to be **re-runnable**. Secrets, the frps binary, the mirror files, the certificate, the Postgres role/database and the config files are all checked before being recreated.

### What it does, in order

| Step | Action |
|------|--------|
| 1 | Installs base packages: `curl socat tar jq nginx postgresql postgresql-contrib ufw ca-certificates gnupg build-essential`, plus Node.js 20.x via NodeSource if `node` is missing |
| 2 | Downloads **frps v0.71.0**, verifies its SHA-256 checksum, installs to `/usr/local/bin/frps` |
| 2b | Mirrors frp release archives (`amd64`, `arm64`) into `/var/www/tfsrun-install/frp/` so VMs need not reach GitHub |
| 3 | Generates persistent secrets in `/etc/tfsrun/` (root-only, mode 600) |
| 4 | Creates the Postgres role `tfsrun` and database `tfsrun` |
| 5 | Installs `acme.sh` and issues a **wildcard cert** for `tfsrun.cloud` and `*.tfsrun.cloud` via Hostinger DNS-01 |
| 6 | Writes `setup-vm.sh` and `setup-ssh-client.sh` into `/var/www/tfsrun-install/` |
| 7 | Writes and enables the nginx site `tfsrun.conf`, removing the default site |
| 8 | Writes and validates `frps.toml`, creates the `frps` systemd unit |
| 9 | Writes the control plane (`server.js`, `package.json`, `schema.sql`, ops scripts), applies the schema, writes `.env`, runs `npm install`, creates the systemd unit |
| 10 | Starts the control plane, then frps, and checks each stays running |
| 11 | Configures the `ufw` firewall |
| 12 | Installs cron jobs for backups and healthchecks |
| 13 | Prints a summary |

---

## 5. Ports and firewall

`ufw` is reset and set to deny incoming by default (outgoing allowed). Only these ports are opened:

| Port | Protocol | Purpose |
|------|----------|---------|
| 22 | TCP | Admin SSH to the server itself |
| 80 | TCP | nginx, redirects to HTTPS |
| 443 | TCP | nginx HTTPS |
| 7000 | TCP | frpc control connections |
| 5002 | TCP | Shared SSH tcpmux HTTP CONNECT port |

**Loopback-only** (never exposed publicly):

| Port | Service |
|------|---------|
| 18080 | frps vhost HTTP (nginx → frps) |
| 7500 | frps dashboard |
| 8080 | Control-plane public API (nginx → Node) |
| 8081 | frps Login-plugin webhook |
| 5432 | Postgres |

> ⚠️ `ufw --force reset` **wipes any existing firewall rules**. If this server runs other services, add their ports afterwards or edit step 11 first.

---

## 6. File and directory layout

| Path | Contents |
|------|----------|
| `/usr/local/bin/frps` | frps binary |
| `/etc/frp/frps.toml` | frps configuration (mode 600) |
| `/etc/tfsrun/` | Secrets and state (mode 700) |
| `/etc/tfsrun/frps_handshake_token` | Shared frp transport token |
| `/etc/tfsrun/frps_dashboard_password` | frps dashboard password |
| `/etc/tfsrun/postgres_tfsrun_password` | Postgres `tfsrun` role password |
| `/etc/tfsrun/certs/fullchain.pem`, `privkey.pem` | Wildcard TLS certificate and key |
| `/var/www/tfsrun-install/` | Public web root: `setup-vm.sh`, `setup-ssh-client.sh`, `frp/*.tar.gz` |
| `/opt/tfsrun/control-plane/` | Node app: `server.js`, `package.json`, `schema.sql`, `.env`, `ops/` |
| `/opt/tfsrun/control-plane/ops/` | `revoke-vm.sh`, `backup-db.sh`, `healthcheck.sh` |
| `/etc/nginx/sites-available/tfsrun.conf` | nginx site (symlinked into `sites-enabled`) |
| `/etc/systemd/system/frps.service` | frps unit |
| `/etc/systemd/system/tfsrun-control-plane.service` | Control-plane unit |
| `/var/backups/tfsrun/` | Nightly database dumps |
| `/var/log/tfsrun-backup.log`, `/var/log/tfsrun-health.log` | Cron job logs |

---

## 7. Authentication model

frp's `auth.token` is not sent to a server plugin in plaintext, so it cannot serve as a per-VM credential. TFSRun therefore uses **two tokens**:

| Token | Scope | Where it lives | Purpose |
|-------|-------|----------------|---------|
| **Handshake token** (`auth.token`) | Same for every VM | `frps.toml`, each VM's `frpc.toml`, control-plane `.env` | Satisfies frp's transport handshake. Grants nothing on its own. |
| **Per-VM token** (`metadatas.tfsrun_token`) | Unique per VM, revocable | VM's `frpc.toml` and `/etc/tfsrun/state.env`; only its SHA-256 hash is stored in Postgres | Checked by the control plane's Login-plugin webhook on every frpc login |

Login flow:

1. frpc connects to frps on `:7000` with the handshake token and its `tfsrun_token` in metadata.
2. frps validates the handshake token itself.
3. frps calls `POST http://127.0.0.1:8081/v1/frp-plugin/login`.
4. The webhook hashes the token and looks it up where `revoked = false`.
5. Match → accept (and update `last_login_at`). No match, missing token, or any internal error → **reject** (fails closed).

---

## 8. Control-plane API

Public base URL: `https://api.tfsrun.cloud/v1`. The service listens on `127.0.0.1:8080`, with nginx in front.

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/v1/healthz` | Liveness check, returns `{"ok": true}` |
| POST | `/v1/vms/identify` | Body `{vm_fingerprint}`. Returns `{known:false}` or `{known:true, vm_id, app_name, subdomain}` |
| POST | `/v1/subdomains/reserve` | Body `{app_name, vm_fingerprint}`. Atomically reserves a name and returns credentials |
| POST | `/v1/subdomains/:app_name/credential` | Body `{vm_id, vm_fingerprint}`. Issues a **fresh** token, invalidating the old one |
| GET | `/v1/subdomains/:app_name/availability` | Read-only check, returns `{available, reason?}` |
| GET | `/v1/subdomains/:app_name/status` | Returns `{subdomain, tunnel_connected}` (queries frps dashboard for a proxy named `<app>-ssh`) |

### `reserve` responses

| HTTP | Meaning |
|------|---------|
| 200 | Reserved. Body includes `subdomain`, `vm_id`, `frp_token`, `frps_addr`, `frps_port`, `tcpmux_httpconnect_port`, `handshake_token` |
| 409 | Name already taken, or this VM already owns a different subdomain |
| 422 | Invalid or reserved name |
| 500 | Internal error |

### Naming rules

- Must match `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$` (lowercase letters, digits, hyphens; no leading/trailing hyphen).
- Reserved and refused: `www api frps tunnel admin ssh mail smtp imap pop ftp ns1 ns2 mx status monitor grafana prometheus dashboard app staging dev test`.
- **One VM owns exactly one subdomain.**
- Reservation is atomic: the `UNIQUE` constraint on `app_name` is the source of truth (`INSERT … ON CONFLICT DO NOTHING`), which avoids a check-then-reserve race.

### Database schema

Single table `vms`:

| Column | Type | Notes |
|--------|------|-------|
| `id` | serial PK | |
| `vm_id` | text, unique | e.g. `vm-a1b2c3d4e5f6` |
| `fingerprint` | text, unique | `sha256:` hash of `/etc/machine-id` |
| `app_name` | text, unique | |
| `subdomain` | text, unique | `<app_name>.tfsrun.cloud` |
| `frp_token_hash` | text, unique | SHA-256 of per-VM token; plaintext never stored |
| `revoked` | boolean | default `false` |
| `created_at` | timestamptz | |
| `last_login_at` | timestamptz | updated on each successful frpc login |

---

## 9. What the generated end-user scripts do

### `setup-vm.sh` (on each VM)

1. Installs `curl`, `jq`, `tar` if missing (apt, dnf, yum or apk).
2. Installs frpc v0.71.0 (`amd64`, `arm64` or `arm`), downloading from the TFSRun mirror first, falling back to GitHub, with checksum verification.
3. Computes a VM fingerprint from `/etc/machine-id`.
4. Idempotency: reuses `/etc/tfsrun/state.env` if it exists; otherwise asks the API whether this fingerprint is already known and, if so, re-issues a credential.
5. Prompts for an application name and reserves it, looping on conflicts.
6. Writes `/etc/frp/frpc.toml` with an SSH `tcpmux` proxy (`localPort = 22`), validates it, and creates and starts `frpc.service`.
7. Waits up to about 20 seconds for `login to server success` in the journal.

### `setup-ssh-client.sh` (on each laptop)

1. Checks for `ssh` and installs `socat` if missing.
2. Prompts for the application name and optionally checks its status via the API (non-fatal).
3. Adds a marker-delimited block to `~/.ssh/config` of the invoking user:

   ```
   # >>> TFSRun:<app> >>>
   Host <app>.tfsrun.cloud
       User ssh
       ProxyCommand socat - PROXY:frps.tfsrun.cloud:%h:%p,proxyport=5002
       ServerAliveInterval 30
   # <<< TFSRun:<app> <<<
   ```
   Re-runs replace only that app's block.
4. Checks DNS resolution and TCP reachability of `frps.tfsrun.cloud:5002`.

Connect with: `ssh ssh@<app>.tfsrun.cloud`

---

## 10. Operations

### Service management

```bash
systemctl status  nginx frps tfsrun-control-plane postgresql
journalctl -u frps -n 50 --no-pager
journalctl -u tfsrun-control-plane -f
```

### Healthcheck

Runs every 5 minutes via cron and appends to `/var/log/tfsrun-health.log`. Run manually:

```bash
sudo /opt/tfsrun/control-plane/ops/healthcheck.sh
```

It checks that nginx, frps, the control plane and Postgres are active, that `/v1/healthz` and the frps dashboard respond, and that the TLS certificate has at least 14 days remaining. The exit code is non-zero if anything fails. **The cron entry only logs; it does not send alerts.** For alerting, wrap it (see the example in the script header) or feed the log to a monitor.

### Backups

- Nightly at **03:00**, `pg_dump` compressed to `/var/backups/tfsrun/tfsrun-<timestamp>.sql.gz` (mode 600), **14-day** retention.
- The `vms` table is the only record of who owns which subdomain. Losing it prevents new reservations, re-runs of `setup-vm.sh` and revocations, though existing tunnels continue only until they need to log in again.
- Restore:
  ```bash
  gunzip -c /var/backups/tfsrun/tfsrun-<timestamp>.sql.gz | psql "$DATABASE_URL"
  ```
- Copy backups off the server; they are only on local disk by default.

### Revoking or restoring a VM

```bash
sudo /opt/tfsrun/control-plane/ops/revoke-vm.sh myapp             # revoke
sudo /opt/tfsrun/control-plane/ops/revoke-vm.sh myapp --restore   # restore
```

Revocation sets `revoked = true` for that one VM. It takes effect on the VM's **next frpc login**; a tunnel that is already connected is not forcibly dropped. To cut it immediately, also restart frps (which disconnects everyone briefly) or remove the proxy through the dashboard. Restoring does not rotate the token, so the VM needs no change.

### Certificate renewal

`acme.sh` installs its own cron job and reloads nginx after renewal (`--reloadcmd "systemctl reload nginx"`). Check with `acme.sh --list`.

### frps dashboard

Bound to `127.0.0.1:7500`, user `admin`, password in `/etc/tfsrun/frps_dashboard_password`. Reach it through an SSH tunnel:

```bash
ssh -L 7500:127.0.0.1:7500 user@<server>   # then open http://localhost:7500
```

### Upgrading frp

Change `FRP_VERSION` in the script (the same value appears in the embedded `setup-vm.sh`) and re-run. The script installs the new frps and mirrors new archives; existing VMs only update when `setup-vm.sh` runs on them again.

### Secrets rotation

Delete the relevant file under `/etc/tfsrun/` and re-run. Rotating the **handshake token** means every VM's `frpc.toml` must be regenerated (re-run `setup-vm.sh` on each). Note that the Postgres password file is only used at role creation, so changing it also requires `ALTER ROLE tfsrun PASSWORD '…'`.

---

## 11. Troubleshooting

| Symptom | Check |
|---------|-------|
| Script exits during certificate issuance | Look at `/tmp/acme_issue.log`; verify the Hostinger token and that DNS has propagated. See known issue A below. |
| `nginx config validation failed` | Certificate files missing in `/etc/tfsrun/certs/`. Confirm step 5 completed. |
| Control plane won't start | `journalctl -u tfsrun-control-plane`; check `.env` and Postgres connectivity |
| frps won't start | `journalctl -u frps`; `frps verify -c /etc/frp/frps.toml` |
| VM says "tunnel did not report a successful connection" | `journalctl -u frpc` on the VM. Look for `auth failed` (handshake mismatch) or a rejection from the plugin (revoked/invalid token). |
| `ssh` hangs or fails | Confirm `socat` is installed, `frps.tfsrun.cloud:5002` is reachable, and the VM has an `ssh` user and sshd running |
| App URL returns 502 | The tunnel is down, or no `http` proxy is defined for that host (see limitation C) |
| Client script says subdomain "not registered" | `setup-vm.sh` hasn't been run for that name |

---

## 12. Known issues and limitations

These come from reading the script; worth reviewing before production use.

**A. Line-continuation bug in certificate issuance (step 5).** After `--debug 2 \` there is a blank line, which ends the command. The redirect to `/tmp/acme_issue.log` and the `|| die` handler then become a separate, empty command. In practice, `acme.sh --issue` runs without log capture and, on failure, `set -e` aborts the script without the friendly error message. Removing the blank line fixes it.

**B. Misleading messages and token persistence (step 5).** The "Wildcard certificate issued and installed" message prints right after the token prompt, before any issuance happens. The token is also only exported for the current run, yet `hostinger_token_set` is created immediately. If the first run fails after the prompt, a re-run will not ask for the token again. Delete `/etc/tfsrun/hostinger_token_set` to be prompted. `acme.sh` normally saves the token in its own account config after a successful issue, which is what renewal depends on.

**C. The SSH proxy is the only one VMs define.** `setup-vm.sh` only creates the SSH `tcpmux` proxy. The nginx and frps wildcard path for `https://<app>.tfsrun.cloud` is in place, but no HTTP/web proxy for the app is generated in `frpc.toml`, so web traffic won't be routed to a VM app until one is added (an `http` proxy with `customDomains = ["<app>.tfsrun.cloud"]`).

**D. No WebSocket headers in nginx.** The wildcard block doesn't set `Upgrade`/`Connection` headers or long timeouts, so WebSocket apps will not work through it as configured.

**E. Unauthenticated public API.** Anyone can call `reserve`, `identify` and `status`, and there is no rate limiting. Someone could claim many names or probe which subdomains exist. Consider nginx `limit_req` and an invite or registration token.

**F. Fingerprint is the VM's identity.** `/v1/subdomains/:app/credential` requires `vm_id` and `vm_fingerprint`, and `identify` returns `vm_id` for any known fingerprint. Anyone who knows or can compute a machine-id hash could obtain that VM's credential. Cloned VM images sharing one `/etc/machine-id` will also collide.

**G. Control plane runs as root**, and `revoke-vm.sh` interpolates the app name directly into SQL. Run the service as an unprivileged user and pass the name as a psql variable.

**H. Service reachability on a fresh apt install.** Postgres and nginx are started by their packages; the script assumes both are running and listening on `127.0.0.1:5432` and the default ports.

---

## 13. Quick reference

| Item | Value |
|------|-------|
| Base domain | `tfsrun.cloud` |
| API | `https://api.tfsrun.cloud/v1` |
| frpc control | `frps.tfsrun.cloud:7000` |
| SSH tcpmux | `frps.tfsrun.cloud:5002` |
| frp version | `0.71.0` |
| Node.js | 20.x |
| Control-plane dir | `/opt/tfsrun/control-plane` |
| Secrets dir | `/etc/tfsrun` |
| Backup schedule | 03:00 daily, 14-day retention |
| Healthcheck schedule | every 5 minutes |