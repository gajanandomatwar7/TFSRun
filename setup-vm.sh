#!/usr/bin/env bash
#
# TFSRun VM Setup — setup-vm.sh
#
# Run as:
#   sudo ./setup-vm.sh
#
# Or:
#   curl -fsSL https://tfsrun.cloud/setup-vm.sh | sudo bash
#
# The VM keeps its existing Linux login users.
# No SSH user is created.
# No SSH keys are generated or enrolled.
#
# SSH access:
#   ssh <existing-user>@<app>.tfsrun.cloud
#
# Example:
#   ssh ubuntu@test1.tfsrun.cloud
#   ssh node@test1.tfsrun.cloud
#
# Password authentication is explicitly enabled through:
#   1. cloud-init configuration
#   2. OpenSSH configuration
#
# Root SSH login remains disabled.
#

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. TFSRun-managed constants
# ---------------------------------------------------------------------------

TFSRUN_API_BASE="https://api.tfsrun.cloud/v1"
MIRROR_HOST="tfsrun.cloud"
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

C_GREEN='\033[0;32m'
C_RED='\033[0;31m'
C_YELLOW='\033[1;33m'
C_RESET='\033[0m'

ok() {
    echo -e "  [${C_GREEN}✓${C_RESET}] $1"
}

fail() {
    echo -e "  [${C_RED}✗${C_RESET}] $1" >&2
}

warn() {
    echo -e "  [${C_YELLOW}!${C_RESET}] $1"
}

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
# Prompt helper
# ---------------------------------------------------------------------------
#
# This script can be piped through curl:
#
#   curl ... | sudo bash
#
# Therefore stdin belongs to curl. Read user input from /dev/tty instead.
#

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

banner "TFSRun VM Setup"
echo

# ---------------------------------------------------------------------------
# 2. Enable password authentication
# ---------------------------------------------------------------------------
#
# IMPORTANT:
#
# We do NOT create any SSH user here.
#
# The VM's existing user is used:
#
#   ubuntu
#   node
#   debian
#   ec2-user
#   etc.
#
# Password authentication is enabled in both cloud-init and sshd.
#
# Root login remains disabled.
# ---------------------------------------------------------------------------

echo "  Configuring SSH password authentication..."

# ----- cloud-init configuration -----

if command -v cloud-init >/dev/null 2>&1 || [[ -d /etc/cloud ]]; then

    mkdir -p /etc/cloud/cloud.cfg.d

    cat > /etc/cloud/cloud.cfg.d/99-tfsrun-ssh.cfg <<'EOF'
# TFSRun SSH configuration
#
# Allow password authentication for normal Linux users.
# Root SSH login remains disabled.

ssh_pwauth: true
disable_root: true
EOF

    ok "cloud-init password authentication enabled"

else
    warn "cloud-init not detected; skipping cloud-init configuration"
fi

# ----- OpenSSH configuration -----

SSHD_TFSRUN_CONFIG="/etc/ssh/sshd_config.d/01-tfsrun-password.conf"

mkdir -p /etc/ssh/sshd_config.d

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
    die "OpenSSH server (sshd) was not found on this VM."
fi

# Verify effective SSH settings.

PASSWORD_AUTH="$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication" {print $2}')"
KBD_AUTH="$(sshd -T 2>/dev/null | awk '$1=="kbdinteractiveauthentication" {print $2}')"
ROOT_LOGIN="$(sshd -T 2>/dev/null | awk '$1=="permitrootlogin" {print $2}')"

[[ "${PASSWORD_AUTH}" == "yes" ]] \
    || die "Effective SSH PasswordAuthentication is not enabled."

[[ "${KBD_AUTH}" == "yes" ]] \
    || die "Effective SSH KbdInteractiveAuthentication is not enabled."

[[ "${ROOT_LOGIN}" == "no" ]] \
    || die "Effective SSH PermitRootLogin is not disabled."

ok "Password authentication enabled for normal users"
ok "Root SSH login disabled"

# ---------------------------------------------------------------------------
# 3. Dependency installation
# ---------------------------------------------------------------------------

need_pkgs=()

command -v curl >/dev/null 2>&1 || need_pkgs+=("curl")
command -v jq   >/dev/null 2>&1 || need_pkgs+=("jq")
command -v tar  >/dev/null 2>&1 || need_pkgs+=("tar")

if [[ ${#need_pkgs[@]} -gt 0 ]]; then

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq || die "apt-get update failed"
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

mkdir -p "${STATE_DIR}" "${FRP_CONF_DIR}"
chmod 700 "${STATE_DIR}"

# ---------------------------------------------------------------------------
# 4. Install FRP
# ---------------------------------------------------------------------------

case "$(uname -m)" in
    x86_64)
        FRP_ARCH="amd64"
        ;;
    aarch64|arm64)
        FRP_ARCH="arm64"
        ;;
    armv7l)
        FRP_ARCH="arm"
        ;;
    *)
        die "Unsupported CPU architecture: $(uname -m)"
        ;;
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

    if curl -fsSL --retry 2 \
        -o "${TMP_DIR}/${ARCHIVE}" \
        "${MIRROR_URL}" 2>/dev/null; then

        ok "Downloaded from TFSRun mirror"

    elif curl -fsSL --retry 3 \
        -o "${TMP_DIR}/${ARCHIVE}" \
        "${UPSTREAM_URL}"; then

        warn "TFSRun mirror unavailable, downloaded from upstream GitHub instead"

    else

        die "Failed to download FRP from both mirror and upstream."

    fi

    if curl -fsSL --retry 2 \
        -o "${TMP_DIR}/checksums.txt" \
        "${CHECKSUM_URL}" 2>/dev/null; then

        EXPECTED="$(
            grep "${ARCHIVE}" "${TMP_DIR}/checksums.txt" |
            awk '{print $1}' || true
        )"

        if [[ -n "${EXPECTED}" ]]; then

            ACTUAL="$(
                sha256sum "${TMP_DIR}/${ARCHIVE}" |
                awk '{print $1}'
            )"

            [[ "${EXPECTED}" == "${ACTUAL}" ]] \
                || die "Checksum mismatch for FRP download."

            ok "Checksum verified"

        else
            warn "Could not find checksum entry; skipping verification"
        fi

    else
        warn "Checksum file unavailable; skipping verification"
    fi

    tar -xzf "${TMP_DIR}/${ARCHIVE}" \
        -C "${TMP_DIR}" \
        || die "Failed to extract FRP archive"

    EXTRACTED_DIR="${TMP_DIR}/frp_${FRP_VERSION}_linux_${FRP_ARCH}"

    [[ -f "${EXTRACTED_DIR}/frpc" ]] \
        || die "frpc binary not found in extracted archive"

    install -m 755 \
        "${EXTRACTED_DIR}/frpc" \
        "${FRP_INSTALL_DIR}/frpc" \
        || die "Failed to install frpc binary"

    rm -rf "${TMP_DIR}"
    trap - EXIT

    ok "FRP ${FRP_VERSION} installed"
fi

# ---------------------------------------------------------------------------
# 5. VM identity
# ---------------------------------------------------------------------------

if [[ -f /etc/machine-id ]] && [[ -s /etc/machine-id ]]; then

    VM_FINGERPRINT="sha256:$(
        sha256sum /etc/machine-id |
        awk '{print $1}'
    )"

else

    FP_FILE="${STATE_DIR}/vm_fingerprint"

    [[ -f "${FP_FILE}" ]] ||
        cat /proc/sys/kernel/random/uuid > "${FP_FILE}"

    VM_FINGERPRINT="sha256:$(
        sha256sum "${FP_FILE}" |
        awk '{print $1}'
    )"

fi

# ---------------------------------------------------------------------------
# 6. Control plane API helper
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
                curl -sS \
                    -w '\n%{http_code}' \
                    -X "${method}" \
                    -H 'Content-Type: application/json' \
                    -d "${body}" \
                    "${TFSRUN_API_BASE}${path}" \
                    2>/dev/null
            )" || resp=""

        else

            resp="$(
                curl -sS \
                    -w '\n%{http_code}' \
                    -X "${method}" \
                    "${TFSRUN_API_BASE}${path}" \
                    2>/dev/null
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
# 7. Existing reservation / VM identification
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

            ok "Control plane recognizes this VM as owner of ${SUBDOMAIN}"

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
# 8. Subdomain selection / reservation
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
# 9. Persist state
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
# 10. Generate frpc.toml
# ---------------------------------------------------------------------------

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

[[proxies]]
name = "${APP_NAME}-http"
type = "http"
customDomains = ["${SUBDOMAIN}"]
localIP = "127.0.0.1"
localPort = 80
EOF

CONF_CHANGED=1

if [[ -f "${FRP_CONF_FILE}" ]] &&
   cmp -s "${NEW_CONF}" "${FRP_CONF_FILE}"; then

    CONF_CHANGED=0

    ok "FRP configuration already up to date"

else

    install -m 600 \
        "${NEW_CONF}" \
        "${FRP_CONF_FILE}" \
        || die "Failed to write ${FRP_CONF_FILE}"

    ok "FRP configuration generated"

fi

rm -f "${NEW_CONF}"

# ---------------------------------------------------------------------------
# 11. Validate FRP configuration
# ---------------------------------------------------------------------------

if ! "${FRP_INSTALL_DIR}/frpc" verify \
    -c "${FRP_CONF_FILE}" \
    >/tmp/frpc_verify.log 2>&1; then

    fail "Generated frpc configuration failed validation:"
    cat /tmp/frpc_verify.log >&2

    die "Not starting frpc with invalid configuration."

fi

ok "FRP configuration validated"

# ---------------------------------------------------------------------------
# 12. systemd service
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

    systemctl daemon-reload \
        || die "systemctl daemon-reload failed"

    systemctl enable frpc >/dev/null 2>&1 \
        || die "Failed to enable frpc service"

    ok "systemd service created"

else

    ok "systemd service already exists"

fi

# ---------------------------------------------------------------------------
# 13. Start/restart FRP
# ---------------------------------------------------------------------------

if systemctl is-active --quiet frpc &&
   [[ "${CONF_CHANGED}" -eq 0 ]]; then

    ok "frpc service already running"

else

    systemctl restart frpc \
        || die "Failed to start frpc. Check: journalctl -u frpc"

    ok "frpc service started"

fi

# ---------------------------------------------------------------------------
# 14. Verify tunnel
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

echo "SSH:"
echo "    Password authentication ✓"
echo "    Existing VM users ✓"
echo "    Root SSH login disabled ✓"
echo "    SSH keys required: No"

echo

echo "Your VM is now connected to TFSRun."

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