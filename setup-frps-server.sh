#!/usr/bin/env bash
#
# TFSRun Public Server Setup — setup-frps-server.sh
#
# THIS IS THE ENTIRE SERVER-SIDE DEPLOYMENT. One file, uploaded once, run
# once:
#     sudo ./setup-frps-server.sh
#
# Nothing else needs to be copied to the server — setup-vm.sh,
# setup-ssh-client.sh, and the full Node.js control-plane (server.js,
# package.json, schema.sql, ops scripts) are embedded below as heredocs and
# written to disk by this script itself. After this finishes, the entire
# user-facing surface of TFSRun is exactly three commands, ever:
#
#   1) sudo ./setup-frps-server.sh                                    (once, on the server)
#   2) curl -fsSL https://tfsrun.cloud/setup-vm.sh | sudo bash         (on each VM)
#   3) curl -fsSL https://tfsrun.cloud/setup-ssh-client.sh | sudo bash (on each laptop)
#
# What this script does, in order:
#   - Installs frps (pinned version, checksum verified) + Node.js
#   - Mirrors frp release archives on this server so VM downloads don't
#     depend on github.com being reachable (falls back to GitHub if this
#     server doesn't have a VM's architecture mirrored)
#   - Installs acme.sh and issues a wildcard TLS cert for *.tfsrun.cloud
#     via Hostinger DNS-01 (HTTP-01 can't do wildcards)
#   - Configures nginx as the single public TLS-terminating front door:
#     serves the install scripts + frp mirror, proxies the control-plane
#     API, proxies app browser traffic into frps
#   - Writes frps.toml (tcpmux SSH relay, Login-plugin webhook for
#     per-VM revocable auth)
#   - Creates the Postgres role/database and applies schema.sql
#   - Writes out and starts the Node.js control-plane (reserve/credential/
#     availability/status API + the frps auth webhook)
#   - Locks down ufw to just the ports actually meant to be public
#   - Schedules nightly DB backups and 5-minute healthchecks via cron
#
# This is a one-box reference deployment. Everything runs on the same
# server; DATABASE_URL and the various *_ADDR values in the generated
# control-plane/.env can be split onto separate hosts later without
# changing setup-vm.sh or setup-ssh-client.sh at all, since they only ever
# talk to the public API and DNS names, never to internals here.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Constants
# ---------------------------------------------------------------------------
BASE_DOMAIN="tfsrun.cloud"
FRPS_HOSTNAME="frps.${BASE_DOMAIN}"     # control-channel hostname (see note below)
API_HOSTNAME="api.${BASE_DOMAIN}"

FRP_VERSION="0.71.0"
FRPS_BIND_PORT=7000            # frpc control connections — public
TCPMUX_HTTPCONNECT_PORT=5002   # shared SSH CONNECT port — public
VHOST_HTTP_PORT=18080          # frps -> plain HTTP, nginx-only (loopback)
DASHBOARD_PORT=7500            # frps dashboard, loopback only
CONTROL_PLANE_PORT=8080        # public API, loopback (nginx fronts it)
FRP_PLUGIN_PORT=8081           # frps Login-plugin webhook, loopback only

FRP_INSTALL_DIR="/usr/local/bin"
FRP_CONF_DIR="/etc/frp"
FRP_CONF_FILE="${FRP_CONF_DIR}/frps.toml"
STATE_DIR="/etc/tfsrun"
CONTROL_PLANE_DIR="/opt/tfsrun/control-plane"
INSTALL_DIR="/var/www/tfsrun-install"   # serves setup-vm.sh / setup-ssh-client.sh for curl | sudo bash

C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_YELLOW='\033[1;33m'; C_RESET='\033[0m'
ok()   { echo -e "  [${C_GREEN}✓${C_RESET}] $1"; }
fail() { echo -e "  [${C_RED}✗${C_RESET}] $1" >&2; }
warn() { echo -e "  [${C_YELLOW}!${C_RESET}] $1"; }
die()  { fail "$1"; exit 1; }
banner() { echo "===================================="; echo "       $1"; echo "===================================="; }

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo ./setup-frps-server.sh" >&2
  exit 1
fi

banner "TFSRun Public Server Setup"
echo
cat <<'NOTE'
DNS you need in place before running this (Hostinger DNS panel):
    A     tfsrun.cloud            -> this server's public IP
    A     *.tfsrun.cloud          -> this server's public IP   (app subdomains)
    A     frps.tfsrun.cloud       -> this server's public IP   (frpc control channel)
    A     api.tfsrun.cloud        -> this server's public IP   (control-plane API)

frps.tfsrun.cloud and api.tfsrun.cloud don't need their own wildcard —
they're plain records in the same zone the wildcard cert already covers.
NOTE
echo
mkdir -p "${STATE_DIR}" "${FRP_CONF_DIR}"
chmod 700 "${STATE_DIR}"

# ---------------------------------------------------------------------------
# 1. Base packages
# ---------------------------------------------------------------------------
apt-get update -qq
apt-get install -y -qq curl socat tar jq nginx postgresql postgresql-contrib ufw \
  ca-certificates gnupg build-essential || die "Base package install failed"
ok "Base packages installed"

if ! command -v node >/dev/null 2>&1; then
  echo "  Installing Node.js 20.x..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1 \
    || die "Failed to add NodeSource repo"
  apt-get install -y -qq nodejs || die "Failed to install Node.js"
fi
ok "Node.js $(node --version) present"

# ---------------------------------------------------------------------------
# 2. Install frps (pinned + checksum verified, same approach as setup-vm.sh)
# ---------------------------------------------------------------------------
case "$(uname -m)" in
  x86_64) FRP_ARCH="amd64" ;;
  aarch64|arm64) FRP_ARCH="arm64" ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

CURRENT_VERSION=""
[[ -x "${FRP_INSTALL_DIR}/frps" ]] && CURRENT_VERSION="$("${FRP_INSTALL_DIR}/frps" --version 2>/dev/null | head -n1 || true)"

if [[ "${CURRENT_VERSION}" == "${FRP_VERSION}" ]]; then
  ok "frps ${FRP_VERSION} already installed"
else
  TMP_DIR="$(mktemp -d)"
  ARCHIVE="frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
  URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${ARCHIVE}"
  CHECKSUM_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_sha256_checksums.txt"

  echo "  Downloading frps v${FRP_VERSION}..."
  curl -fsSL --retry 3 -o "${TMP_DIR}/${ARCHIVE}" "${URL}" || die "Download failed: ${URL}"

  if curl -fsSL --retry 2 -o "${TMP_DIR}/sums.txt" "${CHECKSUM_URL}" 2>/dev/null; then
    EXPECTED="$(grep "${ARCHIVE}" "${TMP_DIR}/sums.txt" | awk '{print $1}' || true)"
    if [[ -n "${EXPECTED}" ]]; then
      ACTUAL="$(sha256sum "${TMP_DIR}/${ARCHIVE}" | awk '{print $1}')"
      [[ "${EXPECTED}" == "${ACTUAL}" ]] || die "Checksum mismatch on frps download"
      ok "Checksum verified"
    fi
  else
    warn "Checksum file unavailable, skipping verification"
  fi

  tar -xzf "${TMP_DIR}/${ARCHIVE}" -C "${TMP_DIR}"
  install -m 755 "${TMP_DIR}/frp_${FRP_VERSION}_linux_${FRP_ARCH}/frps" "${FRP_INSTALL_DIR}/frps"
  rm -rf "${TMP_DIR}"
  ok "frps ${FRP_VERSION} installed"
fi

# ---------------------------------------------------------------------------
# 2b. Mirror frp release archives for VMs to download — setup-vm.sh tries
#    https://tfsrun.cloud/frp/... first, falling back to GitHub only if
#    this server doesn't have that architecture mirrored. This means VMs
#    don't need outbound access to github.com at all in the common case,
#    and downloads come from infrastructure TFSRun controls.
# ---------------------------------------------------------------------------
mkdir -p "${INSTALL_DIR}/frp"
for MIRROR_ARCH in amd64 arm64; do
  MIRROR_ARCHIVE="frp_${FRP_VERSION}_linux_${MIRROR_ARCH}.tar.gz"
  MIRROR_DEST="${INSTALL_DIR}/frp/${MIRROR_ARCHIVE}"
  if [[ -f "${MIRROR_DEST}" ]]; then
    ok "frp mirror already has ${MIRROR_ARCH}"
    continue
  fi
  MIRROR_TMP="$(mktemp -d)"
  MIRROR_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${MIRROR_ARCHIVE}"
  MIRROR_SUMS_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_sha256_checksums.txt"
  if curl -fsSL --retry 3 -o "${MIRROR_TMP}/${MIRROR_ARCHIVE}" "${MIRROR_URL}" 2>/dev/null; then
    if curl -fsSL --retry 2 -o "${MIRROR_TMP}/sums.txt" "${MIRROR_SUMS_URL}" 2>/dev/null; then
      EXPECTED="$(grep "${MIRROR_ARCHIVE}" "${MIRROR_TMP}/sums.txt" | awk '{print $1}' || true)"
      ACTUAL="$(sha256sum "${MIRROR_TMP}/${MIRROR_ARCHIVE}" | awk '{print $1}')"
      if [[ -n "${EXPECTED}" && "${EXPECTED}" != "${ACTUAL}" ]]; then
        warn "Checksum mismatch mirroring ${MIRROR_ARCH}, skipping (setup-vm.sh will fall back to GitHub directly)"
        rm -rf "${MIRROR_TMP}"
        continue
      fi
    fi
    install -m 644 "${MIRROR_TMP}/${MIRROR_ARCHIVE}" "${MIRROR_DEST}"
    ok "Mirrored frp ${MIRROR_ARCH} for VM downloads"
  else
    warn "Could not fetch ${MIRROR_ARCH} to mirror (non-fatal — setup-vm.sh falls back to GitHub for this arch)"
  fi
  rm -rf "${MIRROR_TMP}"
done

# ---------------------------------------------------------------------------
# 3. Generate/reuse persistent secrets before anything references them
# ---------------------------------------------------------------------------
HANDSHAKE_TOKEN_FILE="${STATE_DIR}/frps_handshake_token"
[[ -f "${HANDSHAKE_TOKEN_FILE}" ]] || openssl rand -hex 32 > "${HANDSHAKE_TOKEN_FILE}"
chmod 600 "${HANDSHAKE_TOKEN_FILE}"
FRPS_HANDSHAKE_TOKEN="$(cat "${HANDSHAKE_TOKEN_FILE}")"

DASHBOARD_PW_FILE="${STATE_DIR}/frps_dashboard_password"
[[ -f "${DASHBOARD_PW_FILE}" ]] || openssl rand -hex 16 > "${DASHBOARD_PW_FILE}"
chmod 600 "${DASHBOARD_PW_FILE}"
DASHBOARD_PASSWORD="$(cat "${DASHBOARD_PW_FILE}")"

DB_PW_FILE="${STATE_DIR}/postgres_tfsrun_password"
[[ -f "${DB_PW_FILE}" ]] || openssl rand -hex 16 > "${DB_PW_FILE}"
chmod 600 "${DB_PW_FILE}"
DB_PASSWORD="$(cat "${DB_PW_FILE}")"

ok "Secrets ready (${STATE_DIR}, root-only)"

# ---------------------------------------------------------------------------
# 4. Postgres: create role + database (idempotent)
# ---------------------------------------------------------------------------
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='tfsrun'" | grep -q 1; then
  sudo -u postgres psql -c "CREATE ROLE tfsrun WITH LOGIN PASSWORD '${DB_PASSWORD}';" >/dev/null
fi
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='tfsrun'" | grep -q 1; then
  sudo -u postgres psql -c "CREATE DATABASE tfsrun OWNER tfsrun;" >/dev/null
fi
ok "Postgres role/database ready"

# ---------------------------------------------------------------------------
# 5. acme.sh + wildcard cert via Hostinger DNS-01
#    HTTP-01 cannot issue wildcard certs, so DNS-01 is required here.
# ---------------------------------------------------------------------------
if [[ ! -x "/root/.acme.sh/acme.sh" ]]; then
  echo "  Installing acme.sh..."
  curl -fsSL https://get.acme.sh | sh -s email=admin@${BASE_DOMAIN} >/tmp/acme_install.log 2>&1 \
    || die "acme.sh install failed, see /tmp/acme_install.log"
fi
ACME="/root/.acme.sh/acme.sh"
ok "acme.sh installed"

if [[ ! -f "${STATE_DIR}/hostinger_token_set" ]]; then
  if [[ -z "${HOSTINGER_Token:-}" ]]; then
    echo
    if [[ -e /dev/tty ]]; then
      read -rsp "Enter Hostinger API token (for DNS-01 wildcard cert issuance): " HOSTINGER_Token < /dev/tty
    else
      read -rsp "Enter Hostinger API token (for DNS-01 wildcard cert issuance): " HOSTINGER_Token
    fi
    echo
  fi
  export HOSTINGER_Token
  ok "Wildcard certificate issued and installed"
  touch "${STATE_DIR}/hostinger_token_set"
fi

CERT_DIR="/etc/tfsrun/certs"
mkdir -p "${CERT_DIR}"

if [[ ! -f "${CERT_DIR}/fullchain.pem" ]]; then
  echo "  Issuing wildcard certificate for ${BASE_DOMAIN} / *.${BASE_DOMAIN} (DNS-01, this can take a minute)..."
  "${ACME}" --issue --dns dns_hostinger \
    -d "${BASE_DOMAIN}" -d "*.${BASE_DOMAIN}" \
    --server letsencrypt \
    --dnssleep 180 \
    --debug 2 \

    >/tmp/acme_issue.log 2>&1 || { cat /tmp/acme_issue.log >&2; die "Certificate issuance failed"; }

  "${ACME}" --install-cert -d "${BASE_DOMAIN}" -d "*.${BASE_DOMAIN}" \
    --key-file "${CERT_DIR}/privkey.pem" \
    --fullchain-file "${CERT_DIR}/fullchain.pem" \
    --reloadcmd "systemctl reload nginx" \
    >/tmp/acme_install_cert.log 2>&1 || { cat /tmp/acme_install_cert.log >&2; die "Certificate install failed"; }
  ok "Wildcard certificate issued and installed"
else
  ok "Wildcard certificate already present"
fi
# acme.sh's own cron entry (installed automatically) handles renewal + reload.

# ---------------------------------------------------------------------------
# 6. Host setup-vm.sh / setup-ssh-client.sh for download, so end users never
#    handle files at all — they just run one line:
#        curl -fsSL https://tfsrun.cloud/setup-vm.sh        | sudo bash
#        curl -fsSL https://tfsrun.cloud/setup-ssh-client.sh | sudo bash
#    Embedded directly in THIS script (quoted heredocs, so none of their
#    own $variables get expanded here) — nothing needs to sit alongside
#    this file. This one script is the entire server-side deployment.
# ---------------------------------------------------------------------------
mkdir -p "${INSTALL_DIR}"

cat > "${INSTALL_DIR}/setup-vm.sh" <<'TFSRUN_VMSCRIPT_EOF'
#!/usr/bin/env bash
#
# TFSRun VM Setup — setup-vm.sh
#
# Run as: sudo ./setup-vm.sh
#
# Installs FRP, reserves a subdomain through the TFSRun control plane,
# generates frpc.toml, and runs frpc as a systemd service so the VM is
# reachable at https://<app>.tfsrun.cloud and ssh ssh@<app>.tfsrun.cloud
# without any manual FRP/DNS/TLS configuration.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. TFSRun-managed constants
#    These are fixed by TFSRun and shipped in the script. The user never
#    enters any of this — only the application name (see step 3).
# ---------------------------------------------------------------------------
TFSRUN_API_BASE="https://api.tfsrun.cloud/v1"
MIRROR_HOST="tfsrun.cloud"                # server also mirrors frp binaries, tried before upstream GitHub
FRPS_ADDR_DEFAULT="frps.tfsrun.cloud"
FRPS_PORT_DEFAULT=7000
TCPMUX_PORT_DEFAULT=5002
BASE_DOMAIN="tfsrun.cloud"
FRP_VERSION="0.71.0"

FRP_INSTALL_DIR="/usr/local/bin"
FRP_CONF_DIR="/etc/frp"
FRP_CONF_FILE="${FRP_CONF_DIR}/frpc.toml"
STATE_DIR="/etc/tfsrun"
STATE_FILE="${STATE_DIR}/state.env"
SYSTEMD_UNIT="/etc/systemd/system/frpc.service"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_YELLOW='\033[1;33m'; C_RESET='\033[0m'
ok()   { echo -e "  [${C_GREEN}✓${C_RESET}] $1"; }
fail() { echo -e "  [${C_RED}✗${C_RESET}] $1" >&2; }
warn() { echo -e "  [${C_YELLOW}!${C_RESET}] $1"; }
die()  { fail "$1"; echo; echo "Setup did not complete. Nothing further was started." >&2; exit 1; }

banner() {
  echo "===================================="
  echo "       $1"
  echo "===================================="
}

# This script is meant to be run either as a local file or piped straight
# from the server (curl -fsSL https://tfsrun.cloud/setup-vm.sh | sudo bash).
# In the piped case, this script's own stdin IS the curl output — plain
# `read` would immediately hit EOF instead of waiting for the user to type.
# Reading from /dev/tty instead (the actual terminal, not this script's
# stdin) makes prompts work identically in both cases.
prompt_var() {
  local __prompt_text="$1"
  local -n __out_ref="$2"
  if [[ -e /dev/tty ]]; then
    read -rp "${__prompt_text}" __out_ref < /dev/tty
  elif [[ -t 0 ]]; then
    read -rp "${__prompt_text}" __out_ref
  else
    die "No interactive terminal available to read input. Run this script directly in a terminal (curl -fsSL ... -o setup-vm.sh && sudo ./setup-vm.sh also works)."
  fi
}

# ---------------------------------------------------------------------------
# 1. Root privilege check
# ---------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must be run as root." >&2
  echo "Please run:  sudo ./setup-vm.sh" >&2
  exit 1
fi

banner "TFSRun VM Setup"
echo

# ---------------------------------------------------------------------------
# 2. Dependency installation (curl, jq, tar — needed to talk to the API and
#    unpack FRP). FRP itself is fetched directly from GitHub Releases, not
#    a system package manager, since it isn't packaged upstream.
# ---------------------------------------------------------------------------
need_pkgs=()
command -v curl  >/dev/null 2>&1 || need_pkgs+=("curl")
command -v jq    >/dev/null 2>&1 || need_pkgs+=("jq")
command -v tar   >/dev/null 2>&1 || need_pkgs+=("tar")

if [[ ${#need_pkgs[@]} -gt 0 ]]; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq || die "apt-get update failed"
    apt-get install -y -qq "${need_pkgs[@]}" || die "Failed to install: ${need_pkgs[*]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q "${need_pkgs[@]}" || die "Failed to install: ${need_pkgs[*]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q "${need_pkgs[@]}" || die "Failed to install: ${need_pkgs[*]}"
  elif command -v apk >/dev/null 2>&1; then
    apk add --quiet "${need_pkgs[@]}" || die "Failed to install: ${need_pkgs[*]}"
  else
    die "Unsupported OS: no apt-get/dnf/yum/apk found. Install manually: ${need_pkgs[*]}"
  fi
fi
ok "Dependencies present (curl, jq, tar)"

mkdir -p "${STATE_DIR}" "${FRP_CONF_DIR}"
chmod 700 "${STATE_DIR}"

# ---------------------------------------------------------------------------
# 3. Install FRP (pinned version, idempotent)
# ---------------------------------------------------------------------------
case "$(uname -m)" in
  x86_64)  FRP_ARCH="amd64" ;;
  aarch64|arm64) FRP_ARCH="arm64" ;;
  armv7l)  FRP_ARCH="arm" ;;
  *) die "Unsupported CPU architecture: $(uname -m)" ;;
esac

CURRENT_VERSION=""
if [[ -x "${FRP_INSTALL_DIR}/frpc" ]]; then
  CURRENT_VERSION="$("${FRP_INSTALL_DIR}/frpc" --version 2>/dev/null | head -n1 || true)"
fi

if [[ "${CURRENT_VERSION}" == "${FRP_VERSION}" ]]; then
  ok "FRP ${FRP_VERSION} already installed"
else
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_DIR}"' EXIT

  ARCHIVE="frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
  MIRROR_URL="https://${MIRROR_HOST}/frp/${ARCHIVE}"
  UPSTREAM_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${ARCHIVE}"
  CHECKSUM_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_sha256_checksums.txt"

  echo "  Downloading FRP v${FRP_VERSION} (${FRP_ARCH})..."
  if curl -fsSL --retry 2 -o "${TMP_DIR}/${ARCHIVE}" "${MIRROR_URL}" 2>/dev/null; then
    ok "Downloaded from TFSRun mirror"
  elif curl -fsSL --retry 3 -o "${TMP_DIR}/${ARCHIVE}" "${UPSTREAM_URL}"; then
    warn "TFSRun mirror unavailable, downloaded from upstream GitHub instead"
  else
    die "Failed to download FRP from both ${MIRROR_URL} and ${UPSTREAM_URL}"
  fi

  if curl -fsSL --retry 2 -o "${TMP_DIR}/checksums.txt" "${CHECKSUM_URL}" 2>/dev/null; then
    EXPECTED="$(grep "${ARCHIVE}" "${TMP_DIR}/checksums.txt" | awk '{print $1}' || true)"
    if [[ -n "${EXPECTED}" ]]; then
      ACTUAL="$(sha256sum "${TMP_DIR}/${ARCHIVE}" | awk '{print $1}')"
      [[ "${EXPECTED}" == "${ACTUAL}" ]] || die "Checksum mismatch for FRP download — aborting for safety"
      ok "Checksum verified"
    else
      warn "Could not find checksum entry for ${ARCHIVE}; skipping verification"
    fi
  else
    warn "Checksum file unavailable; skipping verification"
  fi

  tar -xzf "${TMP_DIR}/${ARCHIVE}" -C "${TMP_DIR}" || die "Failed to extract FRP archive"
  EXTRACTED_DIR="${TMP_DIR}/frp_${FRP_VERSION}_linux_${FRP_ARCH}"
  [[ -f "${EXTRACTED_DIR}/frpc" ]] || die "frpc binary not found in extracted archive"

  install -m 755 "${EXTRACTED_DIR}/frpc" "${FRP_INSTALL_DIR}/frpc" || die "Failed to install frpc binary"
  rm -rf "${TMP_DIR}"
  trap - EXIT
  ok "FRP ${FRP_VERSION} installed"
fi

# ---------------------------------------------------------------------------
# 4. VM identity (stable fingerprint used by the control plane)
# ---------------------------------------------------------------------------
if [[ -f /etc/machine-id ]] && [[ -s /etc/machine-id ]]; then
  VM_FINGERPRINT="sha256:$(sha256sum /etc/machine-id | awk '{print $1}')"
else
  FP_FILE="${STATE_DIR}/vm_fingerprint"
  [[ -f "${FP_FILE}" ]] || cat /proc/sys/kernel/random/uuid > "${FP_FILE}"
  VM_FINGERPRINT="sha256:$(sha256sum "${FP_FILE}" | awk '{print $1}')"
fi

api_call() {
  # api_call METHOD PATH [JSON_BODY]
  local method="$1" path="$2" body="${3:-}"
  local attempt=0 max_attempts=3 delay=2
  local resp http_code
  while (( attempt < max_attempts )); do
    if [[ -n "${body}" ]]; then
      resp="$(curl -sS -w '\n%{http_code}' -X "${method}" \
        -H 'Content-Type: application/json' \
        -d "${body}" \
        "${TFSRUN_API_BASE}${path}" 2>/dev/null)" || resp=""
    else
      resp="$(curl -sS -w '\n%{http_code}' -X "${method}" \
        "${TFSRUN_API_BASE}${path}" 2>/dev/null)" || resp=""
    fi
    if [[ -n "${resp}" ]]; then
      http_code="$(echo "${resp}" | tail -n1)"
      LAST_BODY="$(echo "${resp}" | sed '$d')"
      LAST_HTTP_CODE="${http_code}"
      if [[ "${http_code}" =~ ^(2|4)[0-9]{2}$ ]]; then
        return 0
      fi
    fi
    attempt=$((attempt + 1))
    if (( attempt < max_attempts )); then
      warn "Control plane request failed, retrying (${attempt}/${max_attempts})..."
      sleep "${delay}"
      delay=$((delay * 2))
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# 5. Idempotency check — do we already own a subdomain?
# ---------------------------------------------------------------------------
APP_NAME="" SUBDOMAIN="" VM_ID="" FRP_TOKEN="" HANDSHAKE_TOKEN="" FRPS_ADDR="${FRPS_ADDR_DEFAULT}"
FRPS_PORT="${FRPS_PORT_DEFAULT}" TCPMUX_PORT="${TCPMUX_PORT_DEFAULT}"

if [[ -f "${STATE_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
  ok "Existing reservation found locally: ${SUBDOMAIN}"
else
  if api_call POST "/vms/identify" "{\"vm_fingerprint\":\"${VM_FINGERPRINT}\"}"; then
    KNOWN="$(echo "${LAST_BODY}" | jq -r '.known // false')"
    if [[ "${KNOWN}" == "true" ]]; then
      VM_ID="$(echo "${LAST_BODY}" | jq -r '.vm_id')"
      APP_NAME="$(echo "${LAST_BODY}" | jq -r '.app_name')"
      SUBDOMAIN="$(echo "${LAST_BODY}" | jq -r '.subdomain')"
      ok "Control plane recognizes this VM as owner of ${SUBDOMAIN}"

      if api_call POST "/subdomains/${APP_NAME}/credential" \
          "{\"vm_id\":\"${VM_ID}\",\"vm_fingerprint\":\"${VM_FINGERPRINT}\"}"; then
        FRP_TOKEN="$(echo "${LAST_BODY}" | jq -r '.frp_token')"
        HANDSHAKE_TOKEN="$(echo "${LAST_BODY}" | jq -r '.handshake_token')"
        FRPS_ADDR="$(echo "${LAST_BODY}" | jq -r '.frps_addr')"
        FRPS_PORT="$(echo "${LAST_BODY}" | jq -r '.frps_port')"
        TCPMUX_PORT="$(echo "${LAST_BODY}" | jq -r '.tcpmux_httpconnect_port')"
      else
        die "Could not re-issue credential for existing subdomain (HTTP ${LAST_HTTP_CODE:-unknown})"
      fi
    fi
  else
    die "Could not reach TFSRun control plane at ${TFSRUN_API_BASE}. Check network connectivity."
  fi
fi

# ---------------------------------------------------------------------------
# 6/7/8. Subdomain selection, validation, availability + atomic reservation
# ---------------------------------------------------------------------------
HOSTNAME_LABEL_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'

if [[ -z "${SUBDOMAIN}" ]]; then
  echo
  while true; do
    prompt_var "Enter application name: " APP_NAME
    if [[ ! "${APP_NAME}" =~ ${HOSTNAME_LABEL_RE} ]]; then
      fail "Invalid name. Use lowercase letters, numbers, and hyphens only (no spaces, underscores, or symbols)."
      continue
    fi

    echo "  Reserving ${APP_NAME}.${BASE_DOMAIN}..."
    if ! api_call POST "/subdomains/reserve" \
        "{\"app_name\":\"${APP_NAME}\",\"vm_fingerprint\":\"${VM_FINGERPRINT}\"}"; then
      die "Could not reach TFSRun control plane to reserve subdomain."
    fi

    case "${LAST_HTTP_CODE}" in
      200)
        SUBDOMAIN="$(echo "${LAST_BODY}" | jq -r '.subdomain')"
        VM_ID="$(echo "${LAST_BODY}" | jq -r '.vm_id')"
        FRP_TOKEN="$(echo "${LAST_BODY}" | jq -r '.frp_token')"
        HANDSHAKE_TOKEN="$(echo "${LAST_BODY}" | jq -r '.handshake_token')"
        FRPS_ADDR="$(echo "${LAST_BODY}" | jq -r '.frps_addr')"
        FRPS_PORT="$(echo "${LAST_BODY}" | jq -r '.frps_port')"
        TCPMUX_PORT="$(echo "${LAST_BODY}" | jq -r '.tcpmux_httpconnect_port')"
        ok "${SUBDOMAIN} reserved"
        break
        ;;
      409)
        fail "${APP_NAME}.${BASE_DOMAIN} is already in use."
        echo "Please enter another application name:"
        ;;
      422)
        MSG="$(echo "${LAST_BODY}" | jq -r '.message // "invalid name"')"
        fail "${MSG}"
        ;;
      *)
        die "Control plane returned unexpected status ${LAST_HTTP_CODE} while reserving subdomain."
        ;;
    esac
  done
else
  ok "Using existing reservation, skipping subdomain selection"
fi

# Persist state immediately after reservation succeeds, before anything else
# can fail — this is what makes re-runs idempotent even if a later step dies.
{
  echo "APP_NAME='${APP_NAME}'"
  echo "SUBDOMAIN='${SUBDOMAIN}'"
  echo "VM_ID='${VM_ID}'"
  echo "FRP_TOKEN='${FRP_TOKEN}'"
  echo "HANDSHAKE_TOKEN='${HANDSHAKE_TOKEN}'"
  echo "FRPS_ADDR='${FRPS_ADDR}'"
  echo "FRPS_PORT='${FRPS_PORT}'"
  echo "TCPMUX_PORT='${TCPMUX_PORT}'"
} > "${STATE_FILE}"
chmod 600 "${STATE_FILE}"

# ---------------------------------------------------------------------------
# 9/10/11. Generate frpc.toml
#    SSH is exposed via tcpmux + httpconnect so every VM shares a single
#    public port on frps; routing is by hostname, not by a per-VM port.
#
#    Auth note: frp's `auth.token` is never sent to the server plugin in
#    plaintext — frpc uses it to compute a signature, so a server plugin
#    can't check it directly against a per-VM value. TFSRun therefore uses
#    two separate tokens:
#      - `auth.token`      — a single shared handshake token, same for every
#                             VM, just to satisfy frp's own transport
#                             handshake. It does not grant access by itself.
#      - `metadatas.tfsrun_token` — the actual per-VM, revocable credential,
#                             sent as plain custom metadata and checked by
#                             the control plane's frps Login-plugin webhook.
#    Both values come from the control plane per VM; neither is hardcoded
#    in this script.
# ---------------------------------------------------------------------------
NEW_CONF="$(mktemp)"
cat > "${NEW_CONF}" <<EOF
# Generated by TFSRun setup-vm.sh — do not edit by hand.
# Re-running setup-vm.sh will regenerate this file.
serverAddr = "${FRPS_ADDR}"
serverPort = ${FRPS_PORT}

auth.method = "token"
auth.token = "${HANDSHAKE_TOKEN}"
metadatas.tfsrun_token = "${FRP_TOKEN}"

transport.tls.enable = true

[[proxies]]
name = "${APP_NAME}-ssh"
type = "tcpmux"
multiplexer = "httpconnect"
customDomains = ["${SUBDOMAIN}"]
localIP = "127.0.0.1"
localPort = 22
EOF

CONF_CHANGED=1
if [[ -f "${FRP_CONF_FILE}" ]] && cmp -s "${NEW_CONF}" "${FRP_CONF_FILE}"; then
  CONF_CHANGED=0
  ok "Configuration already up to date"
else
  install -m 600 "${NEW_CONF}" "${FRP_CONF_FILE}" || die "Failed to write ${FRP_CONF_FILE}"
  ok "Configuration generated"
fi
rm -f "${NEW_CONF}"

# ---------------------------------------------------------------------------
# 12. Validate configuration before starting anything
# ---------------------------------------------------------------------------
if ! "${FRP_INSTALL_DIR}/frpc" verify -c "${FRP_CONF_FILE}" >/tmp/frpc_verify.log 2>&1; then
  fail "Generated frpc configuration failed validation:"
  cat /tmp/frpc_verify.log >&2
  die "Not starting frpc with invalid configuration."
fi
ok "Configuration validated"

# ---------------------------------------------------------------------------
# 13. systemd service (idempotent)
# ---------------------------------------------------------------------------
if [[ ! -f "${SYSTEMD_UNIT}" ]]; then
  cat > "${SYSTEMD_UNIT}" <<EOF
[Unit]
Description=TFSRun FRP Client (frpc)
After=network.target

[Service]
Type=simple
ExecStart=${FRP_INSTALL_DIR}/frpc -c ${FRP_CONF_FILE}
Restart=on-failure
RestartSec=5
User=root
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload || die "systemctl daemon-reload failed"
  systemctl enable frpc >/dev/null 2>&1 || die "Failed to enable frpc service"
  ok "systemd service created"
else
  ok "systemd service already exists"
fi

if systemctl is-active --quiet frpc && [[ "${CONF_CHANGED}" -eq 0 ]]; then
  ok "frpc service already running"
else
  systemctl restart frpc || die "Failed to start frpc service. Check: journalctl -u frpc"
  ok "frpc service started"
fi

# ---------------------------------------------------------------------------
# 14. Connectivity verification (poll frpc's own status + control plane)
# ---------------------------------------------------------------------------
echo "  Verifying tunnel connectivity..."
TUNNEL_OK=0
for i in $(seq 1 10); do
  if journalctl -u frpc -n 30 --no-pager 2>/dev/null | grep -qi "login to server success"; then
    TUNNEL_OK=1
    break
  fi
  if journalctl -u frpc -n 30 --no-pager 2>/dev/null | grep -qiE "login to server failed|auth failed"; then
    break
  fi
  sleep 2
done

if [[ "${TUNNEL_OK}" -eq 1 ]]; then
  ok "FRP tunnel connected"
else
  fail "FRP tunnel did not report a successful connection within the timeout."
  echo "  Check logs with: journalctl -u frpc -n 50 --no-pager" >&2
  die "Setup did not complete successfully."
fi

# ---------------------------------------------------------------------------
# 15. Final summary
# ---------------------------------------------------------------------------
echo
banner "TFSRun Setup Complete"
echo
echo "Application:"
echo "    ${APP_NAME}"
echo
echo "Hostname:"
echo "    ${SUBDOMAIN}"
echo
echo "FRP:"
echo "    Connected ✓"
echo
echo "Service:"
echo "    frpc.service ✓"
echo
echo "Your VM is now connected to TFSRun."
echo "On your own machine, run: sudo ./setup-ssh-client.sh"
TFSRUN_VMSCRIPT_EOF
chmod 644 "${INSTALL_DIR}/setup-vm.sh"

cat > "${INSTALL_DIR}/setup-ssh-client.sh" <<'TFSRUN_SSHSCRIPT_EOF'
#!/usr/bin/env bash
#
# TFSRun SSH Client Setup — setup-ssh-client.sh
#
# Run as: sudo ./setup-ssh-client.sh
#
# Configures THIS machine so that:
#   ssh ssh@<app>.tfsrun.cloud
# works transparently, even though under the hood traffic is tunneled
# through frps' shared tcpmux/httpconnect port via a ProxyCommand.
#
# This script touches ONLY the local SSH client configuration. It does not
# configure the TFSRun public server, frps, or the VM.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. TFSRun-managed constants
#    Must match the values setup-vm.sh's control plane hands out
#    (frps_addr / tcpmux_httpconnect_port). These are infrastructure-wide,
#    not per-application, so they are fixed here rather than asked from
#    the control plane per app.
# ---------------------------------------------------------------------------
FRPS_ADDR="frps.tfsrun.cloud"
TCPMUX_PORT=5002
BASE_DOMAIN="tfsrun.cloud"
TFSRUN_API_BASE="https://api.tfsrun.cloud/v1"
SSH_USER="ssh"

C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_YELLOW='\033[1;33m'; C_RESET='\033[0m'
ok()   { echo -e "  [${C_GREEN}✓${C_RESET}] $1"; }
fail() { echo -e "  [${C_RED}✗${C_RESET}] $1" >&2; }
warn() { echo -e "  [${C_YELLOW}!${C_RESET}] $1"; }
die()  { fail "$1"; exit 1; }
banner() {
  echo "===================================="
  echo "       $1"
  echo "===================================="
}

# Same rationale as setup-vm.sh: works whether run as a local file or piped
# straight from the server (curl -fsSL https://tfsrun.cloud/setup-ssh-client.sh | sudo bash).
prompt_var() {
  local __prompt_text="$1"
  local -n __out_ref="$2"
  if [[ -e /dev/tty ]]; then
    read -rp "${__prompt_text}" __out_ref < /dev/tty
  elif [[ -t 0 ]]; then
    read -rp "${__prompt_text}" __out_ref
  else
    die "No interactive terminal available to read input. Run this script directly in a terminal (curl -fsSL ... -o setup-ssh-client.sh && sudo ./setup-ssh-client.sh also works)."
  fi
}

# ---------------------------------------------------------------------------
# 1. Root privilege check
# ---------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must be run as root." >&2
  echo "Please run:  sudo ./setup-ssh-client.sh" >&2
  exit 1
fi

banner "TFSRun SSH Client Setup"
echo

# ---------------------------------------------------------------------------
# 2. Verify local environment: OpenSSH client + socat (needed for the
#    ProxyCommand that speaks HTTP CONNECT to frps' tcpmux port)
# ---------------------------------------------------------------------------
command -v ssh >/dev/null 2>&1 || die "OpenSSH client (ssh) not found. Install it and re-run."
ok "OpenSSH client found"

if ! command -v socat >/dev/null 2>&1; then
  echo "  socat is required for TFSRun SSH tunneling, installing..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq socat
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q socat
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q socat
  elif command -v apk >/dev/null 2>&1; then
    apk add --quiet socat
  elif command -v brew >/dev/null 2>&1; then
    brew install socat
  else
    die "Could not auto-install socat on this OS. Please install it manually and re-run."
  fi
  command -v socat >/dev/null 2>&1 || die "socat installation failed"
fi
ok "socat available"

# ---------------------------------------------------------------------------
# 3. Ask for application name, validate
# ---------------------------------------------------------------------------
HOSTNAME_LABEL_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
echo
while true; do
  prompt_var "Enter application name: " APP_NAME
  if [[ "${APP_NAME}" =~ ${HOSTNAME_LABEL_RE} ]]; then
    break
  fi
  fail "Invalid name. Use lowercase letters, numbers, and hyphens only."
done

SUBDOMAIN="${APP_NAME}.${BASE_DOMAIN}"

# ---------------------------------------------------------------------------
# Optional: check the control plane knows about this subdomain. Non-fatal —
# the VM setup and client setup are independent steps, so this is a helpful
# warning, not a hard requirement.
# ---------------------------------------------------------------------------
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  HTTP_CODE="$(curl -sS -o /tmp/tfsrun_status.json -w '%{http_code}' \
    "${TFSRUN_API_BASE}/subdomains/${APP_NAME}/status" 2>/dev/null || echo "000")"
  case "${HTTP_CODE}" in
    200)
      CONNECTED="$(jq -r '.tunnel_connected // false' /tmp/tfsrun_status.json 2>/dev/null || echo false)"
      if [[ "${CONNECTED}" == "true" ]]; then
        ok "Control plane confirms ${SUBDOMAIN} has an active tunnel"
      else
        warn "${SUBDOMAIN} is registered but its tunnel is not currently connected"
      fi
      ;;
    404)
      warn "${SUBDOMAIN} is not registered yet. If you haven't already, run 'sudo ./setup-vm.sh' on the VM first."
      ;;
    000)
      warn "Could not reach the control plane to verify ${SUBDOMAIN} (continuing anyway)"
      ;;
    *)
      warn "Unexpected control plane response (HTTP ${HTTP_CODE}); continuing"
      ;;
  esac
  rm -f /tmp/tfsrun_status.json
fi

# ---------------------------------------------------------------------------
# 4. Write/update local SSH config, idempotently, using marker comments so
#    re-runs replace only this app's block and never touch the rest of the
#    user's SSH config.
# ---------------------------------------------------------------------------
TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
[[ -n "${TARGET_HOME}" ]] || TARGET_HOME="${HOME}"

SSH_DIR="${TARGET_HOME}/.ssh"
SSH_CONFIG="${SSH_DIR}/config"

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
touch "${SSH_CONFIG}"
chmod 600 "${SSH_CONFIG}"
chown "${TARGET_USER}:${TARGET_USER}" "${SSH_DIR}" "${SSH_CONFIG}" 2>/dev/null || true

BEGIN_MARK="# >>> TFSRun:${APP_NAME} >>>"
END_MARK="# <<< TFSRun:${APP_NAME} <<<"

NEW_BLOCK="$(cat <<EOF
${BEGIN_MARK}
Host ${SUBDOMAIN}
    User ${SSH_USER}
    ProxyCommand socat - PROXY:${FRPS_ADDR}:%h:%p,proxyport=${TCPMUX_PORT}
    ServerAliveInterval 30
${END_MARK}
EOF
)"

if grep -qF "${BEGIN_MARK}" "${SSH_CONFIG}" 2>/dev/null; then
  # Replace existing block between markers
  TMP_CONFIG="$(mktemp)"
  awk -v begin="${BEGIN_MARK}" -v end="${END_MARK}" '
    $0 == begin { skip=1 }
    !skip { print }
    $0 == end { skip=0 }
  ' "${SSH_CONFIG}" > "${TMP_CONFIG}"
  echo "${NEW_BLOCK}" >> "${TMP_CONFIG}"
  if cmp -s "${TMP_CONFIG}" "${SSH_CONFIG}"; then
    ok "SSH config already up to date for ${SUBDOMAIN}"
  else
    cp "${TMP_CONFIG}" "${SSH_CONFIG}"
    ok "SSH config updated for ${SUBDOMAIN}"
  fi
  rm -f "${TMP_CONFIG}"
else
  {
    echo ""
    echo "${NEW_BLOCK}"
  } >> "${SSH_CONFIG}"
  ok "SSH config entry created for ${SUBDOMAIN}"
fi
chown "${TARGET_USER}:${TARGET_USER}" "${SSH_CONFIG}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. Verify reachability: DNS resolution + TCP connectivity to the frps
#    tcpmux port. This does NOT confirm the specific VM/app is online —
#    only that the shared TFSRun ingress is reachable from here.
# ---------------------------------------------------------------------------
echo "  Checking DNS resolution for ${FRPS_ADDR}..."
if command -v getent >/dev/null 2>&1 && getent hosts "${FRPS_ADDR}" >/dev/null 2>&1; then
  ok "${FRPS_ADDR} resolves"
elif host "${FRPS_ADDR}" >/dev/null 2>&1; then
  ok "${FRPS_ADDR} resolves"
else
  warn "${FRPS_ADDR} did not resolve — check your network/DNS before connecting"
fi

echo "  Checking TCP connectivity to ${FRPS_ADDR}:${TCPMUX_PORT}..."
if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${FRPS_ADDR}/${TCPMUX_PORT}" 2>/dev/null; then
  ok "TFSRun ingress reachable on port ${TCPMUX_PORT}"
else
  warn "Could not reach ${FRPS_ADDR}:${TCPMUX_PORT} — check firewall/network (SSH will fail until this is reachable)"
fi

# ---------------------------------------------------------------------------
# 6. Final summary
# ---------------------------------------------------------------------------
echo
banner "TFSRun SSH Client Setup Complete"
echo
echo "Application:"
echo "    ${APP_NAME}"
echo
echo "SSH configured:"
echo "    ssh ${SSH_USER}@${SUBDOMAIN}"
echo
echo "Connection available: run the command above to connect."
TFSRUN_SSHSCRIPT_EOF
chmod 644 "${INSTALL_DIR}/setup-ssh-client.sh"

ok "Install scripts embedded and staged at ${INSTALL_DIR}"

# ---------------------------------------------------------------------------
# 7. nginx: single public TLS-terminating front door, handling all three
#    kinds of HTTP(S) traffic this server serves:
#      - tfsrun.cloud (apex only)   -> static setup-vm.sh / setup-ssh-client.sh
#      - api.tfsrun.cloud           -> control-plane API, loopback only
#      - *.tfsrun.cloud (app traffic) -> frps vhost HTTP port, loopback only
#    frps.tfsrun.cloud and the raw tcpmux/frps ports are NOT behind nginx —
#    they're plain TCP (frpc control channel, SSH CONNECT tunnel), so nginx
#    has nothing to terminate there. SSH (port 5002) and HTTP(S) (port 443)
#    are two independent listeners on the same box; nginx only ever handles
#    the latter.
# ---------------------------------------------------------------------------
cat > /etc/nginx/sites-available/tfsrun.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${BASE_DOMAIN} *.${BASE_DOMAIN} ${API_HOSTNAME};
    return 301 https://\$host\$request_uri;
}

# Install scripts — apex domain only (exact match), so it never competes
# with the *.tfsrun.cloud wildcard block below.
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${BASE_DOMAIN};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;

    root ${INSTALL_DIR};
    autoindex off;
    default_type text/plain;

    location / {
        add_header Cache-Control "no-cache";
        try_files \$uri =404;
    }
}

# Control-plane API
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${API_HOSTNAME};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:${CONTROL_PLANE_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

# App traffic — every reserved subdomain lands here, routed onward by frps'
# own vhost router based on the Host header (see setup-vm.sh notes on how
# customDomains -> tunnel mapping works; nginx does not need to know which
# VM owns which hostname, it just forwards Host as-is to frps). Deliberately
# does NOT include the bare apex domain — that's the install-scripts block
# above, matched first anyway since nginx prefers exact server_name matches
# over wildcards, but kept out of this list for clarity.
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name *.${BASE_DOMAIN};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:${VHOST_HTTP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/tfsrun.conf /etc/nginx/sites-enabled/tfsrun.conf
rm -f /etc/nginx/sites-enabled/default

nginx -t || die "nginx config validation failed"
systemctl reload nginx 2>/dev/null || systemctl restart nginx
ok "nginx configured and reloaded"

# ---------------------------------------------------------------------------
# 8. frps.toml
# ---------------------------------------------------------------------------
NEW_FRPS_CONF="$(mktemp)"
cat > "${NEW_FRPS_CONF}" <<EOF
# Generated by TFSRun setup-frps-server.sh — do not edit by hand.
bindAddr = "0.0.0.0"
bindPort = ${FRPS_BIND_PORT}

vhostHTTPPort = ${VHOST_HTTP_PORT}
tcpmuxHTTPConnectPort = ${TCPMUX_HTTPCONNECT_PORT}

# Shared handshake token — satisfies frp's own transport auth. Per-VM
# revocable access is enforced separately by the httpPlugins Login hook
# below, not by this token. See setup-vm.sh's frpc.toml comments.
auth.method = "token"
auth.token = "${FRPS_HANDSHAKE_TOKEN}"

webServer.addr = "127.0.0.1"
webServer.port = ${DASHBOARD_PORT}
webServer.user = "admin"
webServer.password = "${DASHBOARD_PASSWORD}"

[[httpPlugins]]
name = "tfsrun-auth"
addr = "127.0.0.1:${FRP_PLUGIN_PORT}"
path = "/v1/frp-plugin/login"
ops = ["Login"]
EOF

CONF_CHANGED=1
if [[ -f "${FRP_CONF_FILE}" ]] && cmp -s "${NEW_FRPS_CONF}" "${FRP_CONF_FILE}"; then
  CONF_CHANGED=0
  ok "frps configuration already up to date"
else
  install -m 600 "${NEW_FRPS_CONF}" "${FRP_CONF_FILE}"
  ok "frps configuration generated"
fi
rm -f "${NEW_FRPS_CONF}"

if ! "${FRP_INSTALL_DIR}/frps" verify -c "${FRP_CONF_FILE}" >/tmp/frps_verify.log 2>&1; then
  fail "frps configuration failed validation:"
  cat /tmp/frps_verify.log >&2
  die "Not starting frps with invalid configuration."
fi
ok "frps configuration validated"

if [[ ! -f /etc/systemd/system/frps.service ]]; then
  cat > /etc/systemd/system/frps.service <<EOF
[Unit]
Description=TFSRun FRP Server (frps)
After=network.target

[Service]
Type=simple
ExecStart=${FRP_INSTALL_DIR}/frps -c ${FRP_CONF_FILE}
Restart=on-failure
RestartSec=5
User=root
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable frps >/dev/null 2>&1
  ok "frps systemd service created"
fi

# ---------------------------------------------------------------------------
# 9. Control-plane Node service — embedded directly in this script (quoted
#    heredocs, same rationale as setup-vm.sh/setup-ssh-client.sh above).
#    This is the entire "Node.js panel" from earlier in the build, written
#    to disk right here rather than requiring a separate control-plane/
#    directory to be uploaded alongside this file.
# ---------------------------------------------------------------------------
mkdir -p "${CONTROL_PLANE_DIR}" "${CONTROL_PLANE_DIR}/ops"

cat > "${CONTROL_PLANE_DIR}/server.js" <<'TFSRUN_SERVERJS_EOF'
// TFSRun control plane — reference implementation of
// CONTROL-PLANE-API-CONTRACT.md
//
// Two logical surfaces, one process:
//   - Public API (PORT)   — called by setup-vm.sh / setup-ssh-client.sh,
//                            reached via https://api.tfsrun.cloud (nginx).
//   - Plugin webhook (PLUGIN_PORT) — called only by frps, on 127.0.0.1.
//
// Run behind systemd (see setup-frps-server.sh). Both listeners bind to
// 127.0.0.1 — nginx is the only thing exposed publicly on this box.

require('dotenv').config();
const express = require('express');
const crypto = require('crypto');
const { Pool } = require('pg');

const {
  PORT = 8080,
  PLUGIN_PORT = 8081,
  DATABASE_URL,
  FRPS_HANDSHAKE_TOKEN,
  FRPS_ADDR = 'frps.tfsrun.cloud',
  FRPS_PORT = 7000,
  TCPMUX_HTTPCONNECT_PORT = 5002,
  BASE_DOMAIN = 'tfsrun.cloud',
  FRPS_DASHBOARD_URL = 'http://127.0.0.1:7500',
  FRPS_DASHBOARD_USER = 'admin',
  FRPS_DASHBOARD_PASSWORD = '',
} = process.env;

if (!DATABASE_URL) {
  console.error('DATABASE_URL is required. Copy .env.example to .env and fill it in.');
  process.exit(1);
}
if (!FRPS_HANDSHAKE_TOKEN) {
  console.error('FRPS_HANDSHAKE_TOKEN is required and must match frps.toml auth.token.');
  process.exit(1);
}

const pool = new Pool({ connectionString: DATABASE_URL });

// Names a user cannot claim as an app subdomain, since they collide with
// TFSRun's own infrastructure subdomains under the same base domain.
const RESERVED_NAMES = new Set([
  'www', 'api', 'frps', 'tunnel', 'admin', 'ssh', 'mail', 'smtp', 'imap',
  'pop', 'ftp', 'ns1', 'ns2', 'mx', 'status', 'monitor', 'grafana',
  'prometheus', 'dashboard', 'app', 'staging', 'dev', 'test',
]);

const HOSTNAME_LABEL_RE = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/;

function sha256(input) {
  return crypto.createHash('sha256').update(input, 'utf8').digest('hex');
}

function randomToken() {
  return crypto.randomBytes(32).toString('hex');
}

function randomVmId() {
  return `vm-${crypto.randomBytes(6).toString('hex')}`;
}

function infraFields() {
  return {
    frps_addr: FRPS_ADDR,
    frps_port: Number(FRPS_PORT),
    tcpmux_httpconnect_port: Number(TCPMUX_HTTPCONNECT_PORT),
    handshake_token: FRPS_HANDSHAKE_TOKEN,
  };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
const api = express();
api.use(express.json());

api.get('/v1/healthz', (_req, res) => res.json({ ok: true }));

// POST /v1/vms/identify
api.post('/v1/vms/identify', async (req, res) => {
  const { vm_fingerprint } = req.body || {};
  if (!vm_fingerprint) {
    return res.status(422).json({ status: 'invalid', message: 'vm_fingerprint is required' });
  }
  try {
    const { rows } = await pool.query(
      'SELECT vm_id, app_name, subdomain FROM vms WHERE fingerprint = $1 AND revoked = false',
      [vm_fingerprint]
    );
    if (rows.length === 0) return res.json({ known: false });
    const row = rows[0];
    return res.json({
      known: true,
      vm_id: row.vm_id,
      app_name: row.app_name,
      subdomain: row.subdomain,
    });
  } catch (err) {
    console.error('identify error:', err);
    return res.status(500).json({ status: 'error', message: 'internal error' });
  }
});

// POST /v1/subdomains/reserve
api.post('/v1/subdomains/reserve', async (req, res) => {
  const { app_name, vm_fingerprint } = req.body || {};

  if (!app_name || !HOSTNAME_LABEL_RE.test(app_name)) {
    return res.status(422).json({ status: 'invalid', message: 'invalid app_name' });
  }
  if (RESERVED_NAMES.has(app_name)) {
    return res.status(422).json({ status: 'invalid', message: `${app_name} is reserved` });
  }
  if (!vm_fingerprint) {
    return res.status(422).json({ status: 'invalid', message: 'vm_fingerprint is required' });
  }

  const subdomain = `${app_name}.${BASE_DOMAIN}`;

  try {
    // If this fingerprint already owns a (different) subdomain, this is
    // most likely a client that skipped /vms/identify — treat it as
    // idempotent rather than erroring, same as re-running setup-vm.sh
    // would expect.
    const existing = await pool.query(
      'SELECT app_name FROM vms WHERE fingerprint = $1 AND revoked = false',
      [vm_fingerprint]
    );
    if (existing.rows.length > 0 && existing.rows[0].app_name !== app_name) {
      return res.status(409).json({
        status: 'taken',
        message: `This VM already owns ${existing.rows[0].app_name}.${BASE_DOMAIN}. One VM can only own one subdomain.`,
      });
    }

    const vm_id = randomVmId();
    const frp_token = randomToken();
    const frp_token_hash = sha256(frp_token);

    const insert = await pool.query(
      `INSERT INTO vms (vm_id, fingerprint, app_name, subdomain, frp_token_hash)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (app_name) DO NOTHING
       RETURNING vm_id`,
      [vm_id, vm_fingerprint, app_name, subdomain, frp_token_hash]
    );

    if (insert.rows.length === 0) {
      // Unique constraint on app_name blocked it — genuinely taken by
      // someone else. This is the atomic check-and-reserve: the DB
      // constraint is the source of truth, not a prior SELECT.
      return res.status(409).json({ status: 'taken', message: `${subdomain} is already in use.` });
    }

    return res.json({
      status: 'reserved',
      subdomain,
      vm_id,
      frp_token,
      ...infraFields(),
    });
  } catch (err) {
    if (err.code === '23505') { // unique_violation, belt-and-braces
      return res.status(409).json({ status: 'taken', message: `${subdomain} is already in use.` });
    }
    console.error('reserve error:', err);
    return res.status(500).json({ status: 'error', message: 'internal error' });
  }
});

// POST /v1/subdomains/:app_name/credential
api.post('/v1/subdomains/:app_name/credential', async (req, res) => {
  const { app_name } = req.params;
  const { vm_id, vm_fingerprint } = req.body || {};

  if (!vm_id || !vm_fingerprint) {
    return res.status(422).json({ status: 'invalid', message: 'vm_id and vm_fingerprint are required' });
  }

  try {
    const { rows } = await pool.query(
      'SELECT * FROM vms WHERE app_name = $1 AND revoked = false',
      [app_name]
    );
    if (rows.length === 0) {
      return res.status(404).json({ status: 'not_found', message: `${app_name} is not registered` });
    }
    const row = rows[0];
    if (row.vm_id !== vm_id || row.fingerprint !== vm_fingerprint) {
      return res.status(403).json({ status: 'forbidden', message: 'vm_id/fingerprint do not match this subdomain' });
    }

    // We only ever store a hash, so re-issuing means rotating: generate a
    // fresh token and invalidate the old one.
    const frp_token = randomToken();
    const frp_token_hash = sha256(frp_token);
    await pool.query('UPDATE vms SET frp_token_hash = $1 WHERE vm_id = $2', [frp_token_hash, vm_id]);

    return res.json({ frp_token, ...infraFields() });
  } catch (err) {
    console.error('credential error:', err);
    return res.status(500).json({ status: 'error', message: 'internal error' });
  }
});

// GET /v1/subdomains/:app_name/status
// GET /v1/subdomains/:app_name/availability
// Read-only convenience check — NOT used by setup-vm.sh (which reserves
// atomically instead, to avoid a check-then-reserve race). This exists for
// anything else that wants to check without reserving (a future web UI,
// a CLI "is this name free" helper, etc).
api.get('/v1/subdomains/:app_name/availability', async (req, res) => {
  const { app_name } = req.params;
  if (!HOSTNAME_LABEL_RE.test(app_name)) {
    return res.status(422).json({ status: 'invalid', message: 'invalid app_name' });
  }
  if (RESERVED_NAMES.has(app_name)) {
    return res.json({ app_name, available: false, reason: 'reserved' });
  }
  try {
    const { rows } = await pool.query(
      'SELECT 1 FROM vms WHERE app_name = $1 AND revoked = false',
      [app_name]
    );
    return res.json({ app_name, available: rows.length === 0 });
  } catch (err) {
    console.error('availability error:', err);
    return res.status(500).json({ status: 'error', message: 'internal error' });
  }
});

api.get('/v1/subdomains/:app_name/status', async (req, res) => {
  const { app_name } = req.params;
  try {
    const { rows } = await pool.query(
      'SELECT subdomain FROM vms WHERE app_name = $1 AND revoked = false',
      [app_name]
    );
    if (rows.length === 0) {
      return res.status(404).json({ status: 'not_found', message: `${app_name} is not registered` });
    }
    const subdomain = rows[0].subdomain;
    const proxyName = `${app_name}-ssh`;

    let tunnelConnected = false;
    try {
      const auth = Buffer.from(`${FRPS_DASHBOARD_USER}:${FRPS_DASHBOARD_PASSWORD}`).toString('base64');
      const resp = await fetch(`${FRPS_DASHBOARD_URL}/api/proxy/tcpmux`, {
        headers: { Authorization: `Basic ${auth}` },
      });
      if (resp.ok) {
        const data = await resp.json();
        const proxies = data.proxies || data.data || [];
        tunnelConnected = proxies.some((p) => p.name === proxyName);
      }
    } catch (dashboardErr) {
      // frps dashboard unreachable — report unknown-as-disconnected rather
      // than failing the whole request; this is a best-effort liveness
      // signal, not the source of truth for reservation itself.
      console.warn('dashboard status check failed:', dashboardErr.message);
    }

    return res.json({ subdomain, tunnel_connected: tunnelConnected });
  } catch (err) {
    console.error('status error:', err);
    return res.status(500).json({ status: 'error', message: 'internal error' });
  }
});

api.listen(PORT, '127.0.0.1', () => {
  console.log(`TFSRun public API listening on 127.0.0.1:${PORT}`);
});

// ---------------------------------------------------------------------------
// frps Login-plugin webhook (internal only)
//
// frps calls this on every Login operation. auth.token (the shared
// handshake token) is validated by frps itself via auth.method="token" —
// this webhook does NOT re-check that. Its only job is the per-VM,
// revocable check: does content.metas.tfsrun_token match a live VM?
// ---------------------------------------------------------------------------
const plugin = express();
plugin.use(express.json());

plugin.post('/v1/frp-plugin/login', async (req, res) => {
  const { op, content } = req.body || {};
  if (op !== 'Login') {
    // Not an op we care about — allow, unchanged. (Only "Login" is
    // registered against this plugin in frps.toml, so this is defensive.)
    return res.json({ reject: false, unchange: true });
  }

  const token = content && content.metas && content.metas.tfsrun_token;
  if (!token) {
    return res.json({ reject: true, reject_reason: 'missing tfsrun_token metadata' });
  }

  try {
    const frp_token_hash = sha256(token);
    const { rows } = await pool.query(
      'SELECT vm_id FROM vms WHERE frp_token_hash = $1 AND revoked = false',
      [frp_token_hash]
    );
    if (rows.length === 0) {
      return res.json({ reject: true, reject_reason: 'invalid or revoked credential' });
    }
    pool.query('UPDATE vms SET last_login_at = now() WHERE vm_id = $1', [rows[0].vm_id])
      .catch((e) => console.warn('last_login_at update failed:', e.message));

    return res.json({ reject: false, unchange: true });
  } catch (err) {
    console.error('plugin login error:', err);
    // Fail closed: an internal error should not silently grant access.
    return res.json({ reject: true, reject_reason: 'internal error during auth check' });
  }
});

plugin.listen(PLUGIN_PORT, '127.0.0.1', () => {
  console.log(`TFSRun frps-plugin webhook listening on 127.0.0.1:${PLUGIN_PORT}`);
});
TFSRUN_SERVERJS_EOF

cat > "${CONTROL_PLANE_DIR}/package.json" <<'TFSRUN_PKGJSON_EOF'
{
  "name": "tfsrun-control-plane",
  "version": "1.0.0",
  "description": "TFSRun control plane: subdomain reservation and frps Login-plugin auth webhook",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "express": "^4.19.2",
    "pg": "^8.12.0",
    "dotenv": "^16.4.5"
  },
  "engines": {
    "node": ">=18"
  }
}
TFSRUN_PKGJSON_EOF

cat > "${CONTROL_PLANE_DIR}/schema.sql" <<'TFSRUN_SCHEMA_EOF'
-- TFSRun control plane schema

CREATE TABLE IF NOT EXISTS vms (
    id              SERIAL PRIMARY KEY,
    vm_id           TEXT UNIQUE NOT NULL,
    fingerprint     TEXT UNIQUE NOT NULL,
    app_name        TEXT UNIQUE NOT NULL,
    subdomain       TEXT UNIQUE NOT NULL,
    frp_token_hash  TEXT UNIQUE NOT NULL,   -- sha256(frp_token), plaintext is never stored
    revoked         BOOLEAN NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_login_at   TIMESTAMPTZ
);

-- Primary lookup path for the frps Login-plugin webhook: given the token a
-- VM presents, find its row in O(1). This is the hot path, hit on every
-- frpc reconnect, so it needs an index rather than a table scan.
CREATE INDEX IF NOT EXISTS idx_vms_frp_token_hash ON vms (frp_token_hash);

CREATE INDEX IF NOT EXISTS idx_vms_fingerprint ON vms (fingerprint);
CREATE INDEX IF NOT EXISTS idx_vms_app_name ON vms (app_name);
TFSRUN_SCHEMA_EOF

cat > "${CONTROL_PLANE_DIR}/ops/revoke-vm.sh" <<'TFSRUN_REVOKE_EOF'
#!/usr/bin/env bash
#
# revoke-vm.sh — revoke a single VM's access to TFSRun.
#
# Run on the public server as root:
#   sudo ./revoke-vm.sh myapp
#   sudo ./revoke-vm.sh myapp --restore     # un-revoke
#
# What this actually does: sets vms.revoked = true for the given app_name.
# The frps Login-plugin webhook checks `revoked = false` on every login, so
# the effect is immediate on the VM's next reconnect (frpc auto-retries on
# a fixed interval, so this isn't instant, but it's the next attempt, not
# "eventually"). No other VM's row is touched — this is the entire point
# of per-VM credentials instead of one shared frps token.
#
set -euo pipefail

ENV_FILE="/opt/tfsrun/control-plane/.env"
[[ -f "${ENV_FILE}" ]] || { echo "Can't find ${ENV_FILE} — run this on the public server." >&2; exit 1; }
# shellcheck disable=SC1090
source <(grep -E '^DATABASE_URL=' "${ENV_FILE}")

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <app_name> [--restore]" >&2
  exit 1
fi

APP_NAME="$1"
ACTION="revoke"
[[ "${2:-}" == "--restore" ]] && ACTION="restore"

if [[ "${ACTION}" == "revoke" ]]; then
  RESULT="$(psql "${DATABASE_URL}" -tAc \
    "UPDATE vms SET revoked = true WHERE app_name = '${APP_NAME}' RETURNING vm_id;")"
  if [[ -z "${RESULT}" ]]; then
    echo "No VM found with app_name '${APP_NAME}'." >&2
    exit 1
  fi
  echo "Revoked: ${APP_NAME} (vm_id ${RESULT// /})"
  echo "Effective on that VM's next frpc reconnect attempt."
else
  RESULT="$(psql "${DATABASE_URL}" -tAc \
    "UPDATE vms SET revoked = false WHERE app_name = '${APP_NAME}' RETURNING vm_id;")"
  if [[ -z "${RESULT}" ]]; then
    echo "No VM found with app_name '${APP_NAME}'." >&2
    exit 1
  fi
  echo "Restored: ${APP_NAME} (vm_id ${RESULT// /})"
  echo "Note: the VM's OLD frp_token is still what it has locally and is still"
  echo "valid (revoking never rotates it) — no action needed on the VM side."
fi
TFSRUN_REVOKE_EOF

cat > "${CONTROL_PLANE_DIR}/ops/backup-db.sh" <<'TFSRUN_BACKUP_EOF'
#!/usr/bin/env bash
#
# backup-db.sh — dump the tfsrun database with simple rotation.
#
# Install as a daily cron job (as root):
#   0 3 * * * /opt/tfsrun/control-plane/ops/backup-db.sh >> /var/log/tfsrun-backup.log 2>&1
#
# What's actually at risk if this database is lost: every vms row —
# app_name/subdomain reservations and the credential hashes. There is no
# other copy of "who owns myapp.tfsrun.cloud" anywhere else in the system.
# Losing it doesn't take VMs offline immediately (existing tunnels keep
# running), but it means nobody can re-run setup-vm.sh, reserve new names,
# or revoke anyone, until it's restored.
#
set -euo pipefail

ENV_FILE="/opt/tfsrun/control-plane/.env"
BACKUP_DIR="/var/backups/tfsrun"
KEEP_DAYS=14

[[ -f "${ENV_FILE}" ]] || { echo "Can't find ${ENV_FILE} — run this on the public server." >&2; exit 1; }
# shellcheck disable=SC1090
source <(grep -E '^DATABASE_URL=' "${ENV_FILE}")

mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUT_FILE="${BACKUP_DIR}/tfsrun-${TIMESTAMP}.sql.gz"

pg_dump "${DATABASE_URL}" | gzip > "${OUT_FILE}"
chmod 600 "${OUT_FILE}"
echo "Backup written: ${OUT_FILE} ($(du -h "${OUT_FILE}" | cut -f1))"

find "${BACKUP_DIR}" -name 'tfsrun-*.sql.gz' -mtime "+${KEEP_DAYS}" -delete
echo "Pruned backups older than ${KEEP_DAYS} days."

# To restore:
#   gunzip -c /var/backups/tfsrun/tfsrun-<timestamp>.sql.gz | psql "$DATABASE_URL"
TFSRUN_BACKUP_EOF

cat > "${CONTROL_PLANE_DIR}/ops/healthcheck.sh" <<'TFSRUN_HEALTH_EOF'
#!/usr/bin/env bash
#
# healthcheck.sh — quick pass/fail over every server-side component.
#
# Run manually, or on a cron/monitoring interval:
#   */5 * * * * /opt/tfsrun/control-plane/ops/healthcheck.sh || echo "TFSRun unhealthy" | mail -s alert you@example.com
#
set -uo pipefail   # not -e: we want to run every check even if one fails

FAILED=0
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "[OK]   ${desc}"
  else
    echo "[FAIL] ${desc}"
    FAILED=1
  fi
}

check "nginx running"            systemctl is-active --quiet nginx
check "frps running"             systemctl is-active --quiet frps
check "control-plane running"    systemctl is-active --quiet tfsrun-control-plane
check "postgres running"         systemctl is-active --quiet postgresql

check "public API reachable"     curl -fsS --max-time 5 http://127.0.0.1:8080/v1/healthz
check "frps dashboard reachable" curl -fsS --max-time 5 -u "admin:$(grep FRPS_DASHBOARD_PASSWORD /opt/tfsrun/control-plane/.env | cut -d= -f2)" http://127.0.0.1:7500/api/serverinfo

CERT_FILE="/etc/tfsrun/certs/fullchain.pem"
if [[ -f "${CERT_FILE}" ]]; then
  EXPIRY_EPOCH="$(openssl x509 -enddate -noout -in "${CERT_FILE}" | cut -d= -f2 | xargs -I{} date -d {} +%s 2>/dev/null || echo 0)"
  NOW_EPOCH="$(date +%s)"
  DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
  if [[ "${DAYS_LEFT}" -lt 14 ]]; then
    echo "[FAIL] TLS certificate expires in ${DAYS_LEFT} days (acme.sh should have auto-renewed by now — check: acme.sh --list)"
    FAILED=1
  else
    echo "[OK]   TLS certificate valid for ${DAYS_LEFT} more days"
  fi
else
  echo "[FAIL] certificate file not found at ${CERT_FILE}"
  FAILED=1
fi

exit "${FAILED}"
TFSRUN_HEALTH_EOF

chmod +x "${CONTROL_PLANE_DIR}"/ops/*.sh
ok "Control-plane code embedded and staged at ${CONTROL_PLANE_DIR}"

PGPASSWORD="${DB_PASSWORD}" psql -h 127.0.0.1 -U tfsrun -d tfsrun -f "${CONTROL_PLANE_DIR}/schema.sql" >/dev/null \
  || die "Failed to apply schema.sql"
ok "Database schema applied"

cat > "${CONTROL_PLANE_DIR}/.env" <<EOF
PORT=${CONTROL_PLANE_PORT}
PLUGIN_PORT=${FRP_PLUGIN_PORT}
DATABASE_URL=postgres://tfsrun:${DB_PASSWORD}@127.0.0.1:5432/tfsrun
FRPS_HANDSHAKE_TOKEN=${FRPS_HANDSHAKE_TOKEN}
FRPS_ADDR=${FRPS_HOSTNAME}
FRPS_PORT=${FRPS_BIND_PORT}
TCPMUX_HTTPCONNECT_PORT=${TCPMUX_HTTPCONNECT_PORT}
BASE_DOMAIN=${BASE_DOMAIN}
FRPS_DASHBOARD_URL=http://127.0.0.1:${DASHBOARD_PORT}
FRPS_DASHBOARD_USER=admin
FRPS_DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD}
EOF
chmod 600 "${CONTROL_PLANE_DIR}/.env"

( cd "${CONTROL_PLANE_DIR}" && npm install --omit=dev --no-audit --no-fund >/tmp/npm_install.log 2>&1 ) \
  || { cat /tmp/npm_install.log >&2; die "npm install failed"; }
ok "Control-plane dependencies installed"

if [[ ! -f /etc/systemd/system/tfsrun-control-plane.service ]]; then
  cat > /etc/systemd/system/tfsrun-control-plane.service <<EOF
[Unit]
Description=TFSRun Control Plane
After=network.target postgresql.service

[Service]
Type=simple
WorkingDirectory=${CONTROL_PLANE_DIR}
EnvironmentFile=${CONTROL_PLANE_DIR}/.env
ExecStart=$(command -v node) ${CONTROL_PLANE_DIR}/server.js
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable tfsrun-control-plane >/dev/null 2>&1
  ok "Control-plane systemd service created"
fi

# ---------------------------------------------------------------------------
# 10. Start/restart services in dependency order
# ---------------------------------------------------------------------------
systemctl restart tfsrun-control-plane || die "Failed to start control-plane. Check: journalctl -u tfsrun-control-plane"
sleep 1
systemctl is-active --quiet tfsrun-control-plane || die "Control-plane did not stay running. Check: journalctl -u tfsrun-control-plane"
ok "Control-plane running"

if [[ "${CONF_CHANGED}" -eq 1 ]] || ! systemctl is-active --quiet frps; then
  systemctl restart frps || die "Failed to start frps. Check: journalctl -u frps"
fi
sleep 1
systemctl is-active --quiet frps || die "frps did not stay running. Check: journalctl -u frps"
ok "frps running"

# ---------------------------------------------------------------------------
# 11. Firewall — explicit allow-list, everything else stays closed
# ---------------------------------------------------------------------------
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp comment 'admin ssh to this box' >/dev/null
ufw allow 80/tcp comment 'nginx http redirect' >/dev/null
ufw allow 443/tcp comment 'nginx https' >/dev/null
ufw allow ${FRPS_BIND_PORT}/tcp comment 'frpc control channel' >/dev/null
ufw allow ${TCPMUX_HTTPCONNECT_PORT}/tcp comment 'ssh tcpmux' >/dev/null
ufw --force enable >/dev/null
ok "Firewall enabled (22, 80, 443, ${FRPS_BIND_PORT}, ${TCPMUX_HTTPCONNECT_PORT} open; everything else closed)"

# ---------------------------------------------------------------------------
# 12. Wire up backups + monitoring — one script, everything included, so
#    there's nothing left to configure by hand afterward.
# ---------------------------------------------------------------------------
( crontab -l 2>/dev/null | grep -v 'tfsrun/control-plane/ops/backup-db.sh' ; \
  echo "0 3 * * * ${CONTROL_PLANE_DIR}/ops/backup-db.sh >> /var/log/tfsrun-backup.log 2>&1" ) | crontab -
( crontab -l 2>/dev/null | grep -v 'tfsrun/control-plane/ops/healthcheck.sh' ; \
  echo "*/5 * * * * ${CONTROL_PLANE_DIR}/ops/healthcheck.sh >> /var/log/tfsrun-health.log 2>&1" ) | crontab -
ok "Nightly backups and 5-minute healthchecks scheduled"

# ---------------------------------------------------------------------------
# 13. Summary
# ---------------------------------------------------------------------------
echo
banner "TFSRun Public Server Setup Complete"
echo
echo "Public API:      https://${API_HOSTNAME}"
echo "App traffic:     https://<app>.${BASE_DOMAIN}"
echo "SSH endpoint:    ${FRPS_HOSTNAME}:${TCPMUX_HTTPCONNECT_PORT} (via setup-ssh-client.sh)"
echo
echo "Internal-only (not reachable from the internet):"
echo "    frps dashboard      127.0.0.1:${DASHBOARD_PORT}"
echo "    frps plugin webhook 127.0.0.1:${FRP_PLUGIN_PORT}"
echo "    control-plane API   127.0.0.1:${CONTROL_PLANE_PORT} (fronted by nginx)"
echo "    Postgres            127.0.0.1:5432"
echo
echo "frp binaries mirrored for VM downloads (github.com fallback if missing):"
ls "${INSTALL_DIR}/frp/" 2>/dev/null | sed 's/^/    /' || echo "    (none — VMs will fall back to GitHub directly)"
echo
echo "Backups: nightly at 3am -> /var/backups/tfsrun (14-day retention)"
echo "Healthchecks: every 5 min -> /var/log/tfsrun-health.log"
echo
echo "Secrets generated in ${STATE_DIR} (root-only, 600):"
echo "    frps_handshake_token, frps_dashboard_password, postgres_tfsrun_password"
echo
echo "The public API is now live at https://${API_HOSTNAME}/v1"
echo
echo "End users now do this — nothing else, no files to copy:"
echo
echo "  On their VM:"
echo "      curl -fsSL https://${BASE_DOMAIN}/setup-vm.sh | sudo bash"
echo
echo "  On their own machine:"
echo "      curl -fsSL https://${BASE_DOMAIN}/setup-ssh-client.sh | sudo bash"