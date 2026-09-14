#!/usr/bin/env bash
#
# TFSRun VM / Proxmox Node Setup — setup-vm.sh (rev. 2)
#
# Run as:
#   sudo ./setup-vm.sh
# Or:
#   curl -fsSL https://tfsrun.cloud/setup-vm.sh | sudo bash
#
# WHAT CHANGED IN THIS REVISION:
#
#   1. Proxmox web UI blank-page fix. The old version mounted the UI at
#      /pve/ and rewrote asset paths with sub_filter — which silently
#      fails on gzip'd responses and can never rewrite runtime-built
#      URLs. The UI is now served at the SUBDOMAIN ROOT:
#
#          https://<app>.tfsrun.cloud/
#
#      A loopback nginx shim (127.0.0.1:18006) bridges plain HTTP to
#      pveproxy's TLS-only 127.0.0.1:8006. With no path prefix,
#      pveproxy's absolute paths (/pve2/..., /ext6/..., /api2/...)
#      resolve correctly AS-IS: no sub_filter, no Accept-Encoding hacks.
#      CSRF/Origin checks pass because Origin and Host both equal the
#      subdomain. Read-only browsing AND most write operations work.
#
#   2. Dependency installation moved BEFORE any system changes: if
#      packages cannot be installed (e.g. a Proxmox node with only the
#      enterprise repo), the script exits without having touched SSH.
#
#   3. The nginx shim is websocket-ready and allows unlimited streamed
#      request bodies (ISO/template uploads through the UI).
#
#   4. The nginx "default" site is removed ONLY when this script itself
#      installed nginx. A pre-existing nginx is left fully intact.
#
#   5. Idempotent re-runs: frpc.toml, the systemd unit and the nginx
#      shim are regenerated and compared. Running this over an existing
#      installation upgrades it in place (old /pve config is dropped).
#
# SSH behavior (unchanged):
#   - Existing Linux login users are kept. No SSH user is created.
#   - Password authentication enabled (cloud-init + sshd).
#   - Root SSH login disabled on plain VMs.
#   - Root SSH login LEFT AS-IS on Proxmox nodes (cluster nodes
#     authenticate to each other as root: pvecm, live migration,
#     pmxcfs). Override with TFSRUN_FORCE_ROOT_LOGIN_HARDENING=1
#     (WARNING: breaks cluster communication).
#
# Env switches:
#   TFSRUN_EXPOSE_PVE_GUI=0              skip exposing the Proxmox web UI
#   TFSRUN_FORCE_ROOT_LOGIN_HARDENING=1  force-disable root SSH (PVE too)
#
# Files created by this script (for reference / rollback):
#   /etc/cloud/cloud.cfg.d/99-tfsrun-ssh.cfg
#   /etc/ssh/sshd_config.d/01-tfsrun-password.conf
#   /usr/local/bin/frpc
#   /etc/frp/frpc.toml
#   /etc/tfsrun/state.env  (+ /etc/tfsrun/vm_fingerprint)
#   /etc/systemd/system/frpc.service
#   /etc/nginx/conf.d/tfsrun-pve-shim.conf   (Proxmox nodes only)
#   nginx package                              (only if it was absent)
#

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. TFSRun-managed constants
# ---------------------------------------------------------------------------

TFSRUN_API_BASE="https://api.tfsrun.cloud/v1"
MIRROR_HOST="tfsrun.cloud"
FRPS_ADDR_DEFAULT="frps.tfsrun.cloud"
FRPS_PORT_DEFAULT="7000"
TCPMUX_PORT_DEFAULT="5002"
BASE_DOMAIN="tfsrun.cloud"
FRP_VERSION="0.71.0"

FRP_INSTALL_DIR="/usr/local/bin"
FRP_CONF_DIR="/etc/frp"
FRP_CONF_FILE="${FRP_CONF_DIR}/frpc.toml"

STATE_DIR="/etc/tfsrun"
STATE_FILE="${STATE_DIR}/state.env"

SYSTEMD_UNIT="/etc/systemd/system/frpc.service"

# Proxmox GUI bridging
PVE_GUI_PORT=8006      # pveproxy (TLS-only)
PVE_SHIM_PORT=18006    # loopback nginx shim (plain HTTP)
SHIM_CONF="/etc/nginx/conf.d/tfsrun-pve-shim.conf"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

C_GREEN='\033[0;32m'
C_RED='\033[0;31m'
C_YELLOW='\033[1;33m'
C_RESET='\033[0m'

ok()   { echo -e "  [${C_GREEN}✓${C_RESET}] $1"; }
fail() { echo -e "  [${C_RED}✗${C_RESET}] $1" >&2; }
warn() { echo -e "  [${C_YELLOW}!${C_RESET}] $1"; }

die() {
    fail "$1"
    echo
    echo "Setup did not complete. Nothing further was started." >&2
    exit 1
}

banner() {
    echo "===================================="
    echo "       $1"
    echo "===================================="
}

# ---------------------------------------------------------------------------
# Prompt helper — stdin may belong to curl when piped; read from /dev/tty
# ---------------------------------------------------------------------------

prompt_var() {
    local __prompt_text="$1"
    local -n __out_ref="$2"

    if [[ -e /dev/tty ]]; then
        read -rp "${__prompt_text}" __out_ref < /dev/tty
    elif [[ -t 0 ]]; then
        read -rp "${__prompt_text}" __out_ref
    else
        die "No interactive terminal available to read input."
    fi
}

# ---------------------------------------------------------------------------
# 1. Root privilege check
# ---------------------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    echo "Please run:"
    echo "  sudo ./setup-vm.sh"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Proxmox node detection + behaviour decisions
# ---------------------------------------------------------------------------

IS_PVE_NODE=0
if command -v pveversion >/dev/null 2>&1 || [[ -d /etc/pve ]]; then
    IS_PVE_NODE=1
fi

TFSRUN_FORCE_ROOT_LOGIN_HARDENING="${TFSRUN_FORCE_ROOT_LOGIN_HARDENING:-0}"
TFSRUN_EXPOSE_PVE_GUI="${TFSRUN_EXPOSE_PVE_GUI:-1}"

# Root SSH login hardening: default ON for VMs, OFF for PVE nodes
# (cluster nodes authenticate to each other as root over SSH).

HARDEN_ROOT_LOGIN=1
if [[ "${IS_PVE_NODE}" -eq 1 && "${TFSRUN_FORCE_ROOT_LOGIN_HARDENING}" -ne 1 ]]; then
    HARDEN_ROOT_LOGIN=0
fi

# Proxmox GUI exposure (PVE nodes only, unless disabled by env var).

PVE_GUI_ENABLED=0
if [[ "${IS_PVE_NODE}" -eq 1 && "${TFSRUN_EXPOSE_PVE_GUI}" -eq 1 ]]; then
    PVE_GUI_ENABLED=1
fi

# Remember whether nginx already existed, so we only manage the distro
# default site when WE installed it.

NGINX_WAS_PRESENT=0
command -v nginx >/dev/null 2>&1 && NGINX_WAS_PRESENT=1

if [[ "${IS_PVE_NODE}" -eq 1 ]]; then
    banner "TFSRun Proxmox Node Setup"
else
    banner "TFSRun VM Setup"
fi

echo

if [[ "${IS_PVE_NODE}" -eq 1 ]]; then
    warn "Proxmox VE detected on this host."
    if [[ "${HARDEN_ROOT_LOGIN}" -eq 0 ]]; then
        warn "Root SSH login will be LEFT AS-IS (cluster nodes rely on it)."
        warn "Only password authentication for existing users will be added/kept."
        warn "Set TFSRUN_FORCE_ROOT_LOGIN_HARDENING=1 to override this."
    else
        warn "TFSRUN_FORCE_ROOT_LOGIN_HARDENING=1 set: root SSH login WILL be disabled."
        warn "This can break pvecm/migration/pmxcfs communication between cluster nodes."
    fi
    if [[ "${PVE_GUI_ENABLED}" -eq 1 ]]; then
        warn "The Proxmox web UI/API will be exposed at the subdomain ROOT:"
        warn "  https://<app>.${BASE_DOMAIN}/"
    else
        warn "Proxmox GUI exposure disabled (TFSRUN_EXPOSE_PVE_GUI=0)."
    fi
    echo
fi

# ---------------------------------------------------------------------------
# 3. Dependencies — installed BEFORE any system changes, so a failure here
#    leaves the host completely untouched.
# ---------------------------------------------------------------------------

need_pkgs=()

command -v curl >/dev/null 2>&1 || need_pkgs+=("curl")
command -v jq   >/dev/null 2>&1 || need_pkgs+=("jq")
command -v tar  >/dev/null 2>&1 || need_pkgs+=("tar")

if [[ ${#need_pkgs[@]} -gt 0 ]]; then

    if command -v apt-get >/dev/null 2>&1; then

        # apt-get update can exit non-zero when only one repo failed —
        # most commonly Proxmox's "pve-enterprise" repo returning 401
        # without a subscription, while everything else updates fine.
        # Warn and continue; the install below fails loudly if the
        # indexes are genuinely unusable.
        if ! apt-get update -qq 2>/tmp/tfsrun-apt-update.log; then
            warn "apt-get update reported errors (commonly the Proxmox"
            warn "'pve-enterprise' repo returning 401 without a subscription)."
            warn "Continuing — see /tmp/tfsrun-apt-update.log for details."
        fi

        apt-get install -y -qq "${need_pkgs[@]}" \
            || die "Failed to install: ${need_pkgs[*]}"

    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q "${need_pkgs[@]}" \
            || die "Failed to install: ${need_pkgs[*]}"

    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q "${need_pkgs[@]}" \
            || die "Failed to install: ${need_pkgs[*]}"

    elif command -v apk >/dev/null 2>&1; then
        apk add --quiet "${need_pkgs[@]}" \
            || die "Failed to install: ${need_pkgs[*]}"

    else
        die "Unsupported OS: no apt-get/dnf/yum/apk found."
    fi
fi

ok "Dependencies present (curl, jq, tar)"

# nginx is needed only for the Proxmox GUI bridge. Failure here is NOT
# fatal for the script — we degrade gracefully to "GUI not exposed"
# (SSH access is unaffected either way).

if [[ "${PVE_GUI_ENABLED}" -eq 1 && "${NGINX_WAS_PRESENT}" -eq 0 ]]; then

    echo "  Installing nginx (loopback bridge for Proxmox GUI/API access)..."

    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y -qq nginx || PVE_GUI_DEP_FAIL=1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q nginx || PVE_GUI_DEP_FAIL=1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q nginx || PVE_GUI_DEP_FAIL=1
    elif command -v apk >/dev/null 2>&1; then
        apk add --quiet nginx || PVE_GUI_DEP_FAIL=1
    else
        PVE_GUI_DEP_FAIL=1
    fi

    if [[ "${PVE_GUI_DEP_FAIL:-0}" -eq 1 ]] || ! command -v nginx >/dev/null 2>&1; then
        warn "Could not install nginx."
        warn "Skipping Proxmox GUI/API exposure (SSH access is unaffected)."
        PVE_GUI_ENABLED=0
    fi
fi

NGINX_FRESH=0
if [[ "${PVE_GUI_ENABLED}" -eq 1 && "${NGINX_WAS_PRESENT}" -eq 0 ]]; then
    NGINX_FRESH=1
fi

mkdir -p "${STATE_DIR}" "${FRP_CONF_DIR}"
chmod 700 "${STATE_DIR}"

# ---------------------------------------------------------------------------
# 4. Enable password authentication (existing users only; no user created)
# ---------------------------------------------------------------------------

echo "  Configuring SSH password authentication..."

# ----- cloud-init configuration -----

if command -v cloud-init >/dev/null 2>&1 || [[ -d /etc/cloud ]]; then

    mkdir -p /etc/cloud/cloud.cfg.d

    if [[ "${HARDEN_ROOT_LOGIN}" -eq 1 ]]; then

        cat > /etc/cloud/cloud.cfg.d/99-tfsrun-ssh.cfg <<'EOF'
# TFSRun SSH configuration
#
# Allow password authentication for normal Linux users.
# Root SSH login remains disabled.

ssh_pwauth: true
disable_root: true
EOF

    else

        cat > /etc/cloud/cloud.cfg.d/99-tfsrun-ssh.cfg <<'EOF'
# TFSRun SSH configuration
#
# Allow password authentication for normal Linux users.
# Root SSH login is left unmanaged (Proxmox cluster node: root SSH
# between nodes is required for pvecm/migration/pmxcfs).

ssh_pwauth: true
EOF

    fi

    ok "cloud-init password authentication enabled"

else
    warn "cloud-init not detected; skipping cloud-init configuration"
fi

# ----- OpenSSH configuration -----

SSHD_TFSRUN_CONFIG="/etc/ssh/sshd_config.d/01-tfsrun-password.conf"

mkdir -p /etc/ssh/sshd_config.d

if [[ "${HARDEN_ROOT_LOGIN}" -eq 1 ]]; then

    cat > "${SSHD_TFSRUN_CONFIG}" <<'EOF'
# TFSRun SSH configuration
#
# Allow password authentication for normal users.
# Explicitly disable root SSH login.

PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
PermitRootLogin no
EOF

else

    cat > "${SSHD_TFSRUN_CONFIG}" <<'EOF'
# TFSRun SSH configuration
#
# Allow password authentication for normal users.
# PermitRootLogin is intentionally left unmanaged on this Proxmox node:
# cluster operations (pvecm, migrations, pmxcfs) rely on root SSH
# between nodes, and TFSRun does not change that setting here.

PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
EOF

fi

# Validate sshd configuration before applying it.

if command -v sshd >/dev/null 2>&1; then

    if ! sshd -t; then
        rm -f "${SSHD_TFSRUN_CONFIG}"
        die "OpenSSH configuration validation failed."
    fi

    ok "OpenSSH configuration validated"

    if systemctl reload ssh 2>/dev/null; then
        ok "SSH service reloaded"
    elif systemctl reload sshd 2>/dev/null; then
        ok "SSH service reloaded"
    elif systemctl restart ssh 2>/dev/null; then
        ok "SSH service restarted"
    elif systemctl restart sshd 2>/dev/null; then
        ok "SSH service restarted"
    else
        die "Could not reload/restart SSH service."
    fi

else
    die "OpenSSH server (sshd) was not found on this host."
fi

# Verify effective SSH settings.

PASSWORD_AUTH="$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication" {print $2}')"
KBD_AUTH="$(sshd -T 2>/dev/null | awk '$1=="kbdinteractiveauthentication" {print $2}')"
ROOT_LOGIN="$(sshd -T 2>/dev/null | awk '$1=="permitrootlogin" {print $2}')"

[[ "${PASSWORD_AUTH}" == "yes" ]] \
    || die "Effective SSH PasswordAuthentication is not enabled."

[[ "${KBD_AUTH}" == "yes" ]] \
    || die "Effective SSH KbdInteractiveAuthentication is not enabled."

if [[ "${HARDEN_ROOT_LOGIN}" -eq 1 ]]; then

    [[ "${ROOT_LOGIN}" == "no" ]] \
        || die "Effective SSH PermitRootLogin is not disabled."

    ok "Password authentication enabled for normal users"
    ok "Root SSH login disabled"

else

    ok "Password authentication enabled for normal users"
    ok "Root SSH login left unchanged (${ROOT_LOGIN}) — Proxmox cluster node"

fi

# ---------------------------------------------------------------------------
# 5. Install FRP
# ---------------------------------------------------------------------------

case "$(uname -m)" in
    x86_64)         FRP_ARCH="amd64" ;;
    aarch64|arm64)  FRP_ARCH="arm64" ;;
    armv7l)         FRP_ARCH="arm" ;;
    *)              die "Unsupported CPU architecture: $(uname -m)" ;;
esac

CURRENT_VERSION=""

if [[ -x "${FRP_INSTALL_DIR}/frpc" ]]; then
    CURRENT_VERSION="$(
        "${FRP_INSTALL_DIR}/frpc" --version 2>/dev/null |
        head -n1 || true
    )"
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
        die "Failed to download FRP from both mirror and upstream."
    fi

    if curl -fsSL --retry 2 -o "${TMP_DIR}/checksums.txt" "${CHECKSUM_URL}" 2>/dev/null; then

        EXPECTED="$(
            grep "${ARCHIVE}" "${TMP_DIR}/checksums.txt" |
            awk '{print $1}' || true
        )"

        if [[ -n "${EXPECTED}" ]]; then
            ACTUAL="$(sha256sum "${TMP_DIR}/${ARCHIVE}" | awk '{print $1}')"
            [[ "${EXPECTED}" == "${ACTUAL}" ]] \
                || die "Checksum mismatch for FRP download."
            ok "Checksum verified"
        else
            warn "Could not find checksum entry; skipping verification"
        fi

    else
        warn "Checksum file unavailable; skipping verification"
    fi

    tar -xzf "${TMP_DIR}/${ARCHIVE}" -C "${TMP_DIR}" \
        || die "Failed to extract FRP archive"

    EXTRACTED_DIR="${TMP_DIR}/frp_${FRP_VERSION}_linux_${FRP_ARCH}"

    [[ -f "${EXTRACTED_DIR}/frpc" ]] \
        || die "frpc binary not found in extracted archive"

    install -m 755 "${EXTRACTED_DIR}/frpc" "${FRP_INSTALL_DIR}/frpc" \
        || die "Failed to install frpc binary"

    rm -rf "${TMP_DIR}"
    trap - EXIT

    ok "FRP ${FRP_VERSION} installed"
fi

# ---------------------------------------------------------------------------
# 6. Host identity
# ---------------------------------------------------------------------------

if [[ -f /etc/machine-id ]] && [[ -s /etc/machine-id ]]; then

    VM_FINGERPRINT="sha256:$(
        sha256sum /etc/machine-id | awk '{print $1}'
    )"

else

    FP_FILE="${STATE_DIR}/vm_fingerprint"

    [[ -f "${FP_FILE}" ]] ||
        cat /proc/sys/kernel/random/uuid > "${FP_FILE}"

    VM_FINGERPRINT="sha256:$(
        sha256sum "${FP_FILE}" | awk '{print $1}'
    )"

fi

# ---------------------------------------------------------------------------
# 7. Control plane API helper
# ---------------------------------------------------------------------------

api_call() {

    local method="$1"
    local path="$2"
    local body="${3:-}"

    local attempt=0
    local max_attempts=3
    local delay=2

    local resp
    local http_code

    while (( attempt < max_attempts )); do

        if [[ -n "${body}" ]]; then
            resp="$(
                curl -sS -w '\n%{http_code}' -X "${method}" \
                    -H 'Content-Type: application/json' \
                    -d "${body}" \
                    "${TFSRUN_API_BASE}${path}" 2>/dev/null
            )" || resp=""
        else
            resp="$(
                curl -sS -w '\n%{http_code}' -X "${method}" \
                    "${TFSRUN_API_BASE}${path}" 2>/dev/null
            )" || resp=""
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
# 8. Existing reservation / host identification
# ---------------------------------------------------------------------------

APP_NAME=""
SUBDOMAIN=""
VM_ID=""
FRP_TOKEN=""
HANDSHAKE_TOKEN=""

FRPS_ADDR="${FRPS_ADDR_DEFAULT}"
FRPS_PORT="${FRPS_PORT_DEFAULT}"
TCPMUX_PORT="${TCPMUX_PORT_DEFAULT}"

if [[ -f "${STATE_FILE}" ]]; then

    # shellcheck disable=SC1090
    source "${STATE_FILE}"

    ok "Existing reservation found locally: ${SUBDOMAIN}"

else

    if api_call POST \
        "/vms/identify" \
        "{\"vm_fingerprint\":\"${VM_FINGERPRINT}\"}"; then

        KNOWN="$(echo "${LAST_BODY}" | jq -r '.known // false')"

        if [[ "${KNOWN}" == "true" ]]; then

            VM_ID="$(echo "${LAST_BODY}" | jq -r '.vm_id')"
            APP_NAME="$(echo "${LAST_BODY}" | jq -r '.app_name')"
            SUBDOMAIN="$(echo "${LAST_BODY}" | jq -r '.subdomain')"

            ok "Control plane recognizes this host as owner of ${SUBDOMAIN}"

            if api_call POST \
                "/subdomains/${APP_NAME}/credential" \
                "{\"vm_id\":\"${VM_ID}\",\"vm_fingerprint\":\"${VM_FINGERPRINT}\"}"; then

                FRP_TOKEN="$(echo "${LAST_BODY}" | jq -r '.frp_token')"
                HANDSHAKE_TOKEN="$(echo "${LAST_BODY}" | jq -r '.handshake_token')"
                FRPS_ADDR="$(echo "${LAST_BODY}" | jq -r '.frps_addr')"
                FRPS_PORT="$(echo "${LAST_BODY}" | jq -r '.frps_port')"
                TCPMUX_PORT="$(echo "${LAST_BODY}" | jq -r '.tcpmux_httpconnect_port')"

            else

                die "Could not re-issue credential for existing subdomain."

            fi
        fi

    else

        die "Could not reach TFSRun control plane at ${TFSRUN_API_BASE}."

    fi
fi

# ---------------------------------------------------------------------------
# 9. Subdomain selection / reservation
# ---------------------------------------------------------------------------

HOSTNAME_LABEL_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'

if [[ -z "${SUBDOMAIN}" ]]; then

    echo

    while true; do

        prompt_var "Enter application name: " APP_NAME

        if [[ ! "${APP_NAME}" =~ ${HOSTNAME_LABEL_RE} ]]; then
            fail "Invalid name. Use lowercase letters, numbers, and hyphens only."
            continue
        fi

        echo "  Reserving ${APP_NAME}.${BASE_DOMAIN}..."

        if ! api_call POST \
            "/subdomains/reserve" \
            "{\"app_name\":\"${APP_NAME}\",\"vm_fingerprint\":\"${VM_FINGERPRINT}\"}"; then
            die "Could not reach TFSRun control plane."
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
                die "Unexpected control plane response: HTTP ${LAST_HTTP_CODE}"
                ;;
        esac

    done

else

    ok "Using existing reservation, skipping subdomain selection"

fi

# ---------------------------------------------------------------------------
# 10. Persist state
# ---------------------------------------------------------------------------

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
# 11. Proxmox web UI shim (loopback nginx: plain HTTP -> pveproxy TLS)
# ---------------------------------------------------------------------------
#
# Design (rev. 2): the subdomain ROOT is the Proxmox UI. No /pve/ prefix,
# no sub_filter path rewriting. pveproxy's absolute paths resolve as-is,
# CSRF Origin/Host checks match, and the old blank-page failure mode is
# designed out entirely.
#
# Known limits: noVNC console websockets require Upgrade pass-through on
# the TFSRun edge (test it); SPICE needs direct node connectivity and will
# not work through the domain. Guaranteed full-fidelity fallback:
#   ssh -L 8006:localhost:8006 <user>@<app>.tfsrun.cloud
#   -> open https://localhost:8006
#
# conf.d/*.conf is included in nginx's http{} context on both Debian and
# RHEL layouts, so the map directive below is valid where it sits.

if [[ "${PVE_GUI_ENABLED}" -eq 1 ]]; then

    mkdir -p /etc/nginx/conf.d

    NEW_SHIM="$(mktemp)"

    cat > "${NEW_SHIM}" <<EOF
# Generated by TFSRun setup-vm.sh. Do not edit by hand.
#
# Loopback-only bridge: plain HTTP in (from the frps tunnel) -> Proxmox's
# TLS-only pveproxy on 127.0.0.1:${PVE_GUI_PORT}.
#
# The whole subdomain ROOT is the Proxmox UI, so pveproxy's absolute
# paths (/pve2/..., /ext6/..., /api2/...) work as-is. No sub_filter,
# no Accept-Encoding handling — the blank-page class of bugs is
# designed out.

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 127.0.0.1:${PVE_SHIM_PORT};
    server_name _;

    location / {
        proxy_pass https://127.0.0.1:${PVE_GUI_PORT};
        proxy_ssl_verify off;

        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        # ISO/template uploads through the UI: no size limit, streamed
        # end-to-end (not buffered to local disk).
        client_max_body_size 0;
        proxy_request_buffering off;

        # Long-lived sessions (consoles).
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

    SHIM_CHANGED=1
    if [[ -f "${SHIM_CONF}" ]] && cmp -s "${NEW_SHIM}" "${SHIM_CONF}"; then
        SHIM_CHANGED=0
        ok "nginx shim configuration already up to date"
    else
        install -m 644 "${NEW_SHIM}" "${SHIM_CONF}" \
            || die "Failed to write ${SHIM_CONF}"
        ok "nginx shim configuration written"
    fi

    rm -f "${NEW_SHIM}"

    # Only when THIS script installed nginx: keep the node's port 80 in
    # its previous state (nothing listening) by dropping the distro
    # default site. A pre-existing nginx is never touched here.
    if [[ "${NGINX_FRESH}" -eq 1 ]]; then
        rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
        rm -f /etc/nginx/conf.d/default.conf      2>/dev/null || true
    fi

    if ! nginx -t -q 2>/tmp/tfsrun-nginx-shim.log; then
        fail "nginx configuration failed validation:"
        cat /tmp/tfsrun-nginx-shim.log >&2
        rm -f "${SHIM_CONF}"
        warn "Skipping Proxmox GUI/API exposure (SSH access is unaffected)."
        PVE_GUI_ENABLED=0
    else
        ok "nginx configuration validated"

        if systemctl is-active --quiet nginx; then
            if [[ "${SHIM_CHANGED}" -eq 1 ]]; then
                systemctl reload nginx 2>/dev/null \
                    || systemctl restart nginx \
                    || die "Failed to reload nginx for the Proxmox GUI shim."
                ok "nginx reloaded"
            fi
        else
            if [[ "${NGINX_FRESH}" -eq 1 ]]; then
                systemctl enable nginx >/dev/null 2>&1 || true
            fi
            systemctl restart nginx \
                || die "Failed to start nginx for the Proxmox GUI shim."
            ok "nginx started"
        fi

        ok "Proxmox GUI/API shim: 127.0.0.1:${PVE_SHIM_PORT} -> https://127.0.0.1:${PVE_GUI_PORT}"
    fi

else

    # GUI disabled — clean up a shim left behind by a previous run.
    if [[ -f "${SHIM_CONF}" ]]; then
        rm -f "${SHIM_CONF}"
        if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
            nginx -t -q 2>/dev/null && systemctl reload nginx 2>/dev/null || true
        fi
        ok "Removed leftover Proxmox GUI shim (GUI exposure disabled)"
    fi

fi

# ---------------------------------------------------------------------------
# 12. Generate frpc.toml
# ---------------------------------------------------------------------------

# Domain root target:
#   - PVE node, GUI enabled : the loopback nginx shim (Proxmox UI)
#   - plain VM / GUI off    : the host's own web server on port 80

HTTP_LOCAL_PORT=80
if [[ "${PVE_GUI_ENABLED}" -eq 1 ]]; then
    HTTP_LOCAL_PORT="${PVE_SHIM_PORT}"
fi

NEW_CONF="$(mktemp)"

cat > "${NEW_CONF}" <<EOF
# Generated by TFSRun setup-vm.sh
# Do not edit by hand.

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

# Domain root. On a Proxmox node with the GUI enabled this is the
# loopback nginx shim bridging to pveproxy (https://127.0.0.1:8006),
# so the Proxmox web UI is served at https://${SUBDOMAIN}/ AS-IS —
# no path rewriting. Otherwise it forwards to the host's own web
# server on port 80, as before.
[[proxies]]
name = "${APP_NAME}-http"
type = "http"
customDomains = ["${SUBDOMAIN}"]
locations = ["/"]
localIP = "127.0.0.1"
localPort = ${HTTP_LOCAL_PORT}
EOF

CONF_CHANGED=1

if [[ -f "${FRP_CONF_FILE}" ]] && cmp -s "${NEW_CONF}" "${FRP_CONF_FILE}"; then
    CONF_CHANGED=0
    ok "FRP configuration already up to date"
else
    install -m 600 "${NEW_CONF}" "${FRP_CONF_FILE}" \
        || die "Failed to write ${FRP_CONF_FILE}"
    ok "FRP configuration generated"
fi

rm -f "${NEW_CONF}"

# ---------------------------------------------------------------------------
# 13. Validate FRP configuration
# ---------------------------------------------------------------------------

if ! "${FRP_INSTALL_DIR}/frpc" verify -c "${FRP_CONF_FILE}" \
    >/tmp/frpc_verify.log 2>&1; then

    fail "Generated frpc configuration failed validation:"
    cat /tmp/frpc_verify.log >&2

    die "Not starting frpc with invalid configuration."

fi

ok "FRP configuration validated"

# ---------------------------------------------------------------------------
# 14. systemd service (compare-and-update so re-runs upgrade the unit)
# ---------------------------------------------------------------------------

NEW_UNIT="$(mktemp)"

cat > "${NEW_UNIT}" <<EOF
[Unit]
Description=TFSRun FRP Client (frpc)
Wants=network-online.target
After=network-online.target

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

UNIT_CHANGED=0

if [[ -f "${SYSTEMD_UNIT}" ]] && cmp -s "${NEW_UNIT}" "${SYSTEMD_UNIT}"; then
    ok "systemd service already up to date"
else
    install -m 644 "${NEW_UNIT}" "${SYSTEMD_UNIT}" \
        || die "Failed to write ${SYSTEMD_UNIT}"
    UNIT_CHANGED=1
    systemctl daemon-reload \
        || die "systemctl daemon-reload failed"
    systemctl enable frpc >/dev/null 2>&1 \
        || die "Failed to enable frpc service"
    ok "systemd service created/updated"
fi

rm -f "${NEW_UNIT}"

# ---------------------------------------------------------------------------
# 15. Start/restart FRP
# ---------------------------------------------------------------------------

if systemctl is-active --quiet frpc &&
   [[ "${CONF_CHANGED}" -eq 0 && "${UNIT_CHANGED}" -eq 0 ]]; then

    ok "frpc service already running"

else

    systemctl restart frpc \
        || die "Failed to start frpc. Check: journalctl -u frpc"

    ok "frpc service started"

fi

# ---------------------------------------------------------------------------
# 16. Verify tunnel
# ---------------------------------------------------------------------------

echo "  Verifying tunnel connectivity..."

TUNNEL_OK=0

for i in $(seq 1 10); do

    if journalctl -u frpc -n 30 --no-pager 2>/dev/null |
       grep -qi "login to server success"; then
        TUNNEL_OK=1
        break
    fi

    if journalctl -u frpc -n 30 --no-pager 2>/dev/null |
       grep -qiE "login to server failed|auth failed"; then
        break
    fi

    sleep 2

done

if [[ "${TUNNEL_OK}" -eq 1 ]]; then
    ok "FRP tunnel connected"
else
    fail "FRP tunnel did not report a successful connection."
    echo "  Check logs with:"
    echo "    journalctl -u frpc -n 50 --no-pager"
    die "Setup did not complete successfully."
fi

# ---------------------------------------------------------------------------
# 17. Final summary
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

echo "SSH:"
echo "    Password authentication ✓"
echo "    Existing host users ✓"

if [[ "${HARDEN_ROOT_LOGIN}" -eq 1 ]]; then
    echo "    Root SSH login disabled ✓"
else
    echo "    Root SSH login: left unchanged (Proxmox cluster node)"
fi

echo "    SSH keys required: No"

echo

if [[ "${PVE_GUI_ENABLED}" -eq 1 ]]; then
    echo "Proxmox web UI / API:"
    echo "    https://${SUBDOMAIN}/"
    echo "    (log in with your normal Proxmox credentials)"
    echo "    Consoles: noVNC depends on websocket pass-through on the"
    echo "    server side — if a console hangs, use the SSH tunnel:"
    echo "      ssh -L 8006:localhost:8006 <user>@${SUBDOMAIN}"
    echo "    and open https://localhost:8006 locally."
    echo
fi

echo "Your host is now connected to TFSRun."

echo

echo "From your client machine, run:"
echo "    curl -fsSL https://${BASE_DOMAIN}/setup-ssh-client.sh | sudo bash"

echo

echo "The client setup will ask for:"
echo "    Application name"
echo "    SSH username"

echo

echo "Then connect with:"
echo "    ssh <username>@${SUBDOMAIN}"