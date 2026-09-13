#!/usr/bin/env bash
#
# TFSRun SSH Client Setup — setup-ssh-client.sh
#
# Run as:
#   sudo ./setup-ssh-client.sh
#
# Or:
#   curl -fsSL https://tfsrun.cloud/setup-ssh-client.sh | sudo bash
#
# This configures the LOCAL machine so:
#
#   ssh <username>@<app>.tfsrun.cloud
#
# works through the TFSRun FRP TCPMUX/HTTP CONNECT tunnel.
#
# No SSH keys are generated.
# No SSH keys are enrolled.
# No enrollment code is required.
#
# The username is the EXISTING Linux user on the VM.
#

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. TFSRun-managed constants
# ---------------------------------------------------------------------------

FRPS_ADDR="frps.tfsrun.cloud"
TCPMUX_PORT=5002
BASE_DOMAIN="tfsrun.cloud"
TFSRUN_API_BASE="https://api.tfsrun.cloud/v1"

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

prompt_var() {

    local __prompt_text="$1"
    local -n __out_ref="$2"

    if [[ -e /dev/tty ]]; then

        read -rp "${__prompt_text}" \
            __out_ref < /dev/tty

    elif [[ -t 0 ]]; then

        read -rp "${__prompt_text}" \
            __out_ref

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
    echo "  sudo ./setup-ssh-client.sh"

    exit 1
fi

banner "TFSRun SSH Client Setup"

echo

# ---------------------------------------------------------------------------
# 2. Verify OpenSSH client
# ---------------------------------------------------------------------------

command -v ssh >/dev/null 2>&1 \
    || die "OpenSSH client (ssh) not found. Install it and re-run."

ok "OpenSSH client found"

# ---------------------------------------------------------------------------
# 3. Install socat if required
# ---------------------------------------------------------------------------

install_pkg() {

    local pkg="$1"

    if command -v apt-get >/dev/null 2>&1; then

        apt-get update -qq &&
        apt-get install -y -qq "${pkg}"

    elif command -v dnf >/dev/null 2>&1; then

        dnf install -y -q "${pkg}"

    elif command -v yum >/dev/null 2>&1; then

        yum install -y -q "${pkg}"

    elif command -v apk >/dev/null 2>&1; then

        apk add --quiet "${pkg}"

    elif command -v brew >/dev/null 2>&1; then

        brew install "${pkg}"

    else

        return 1

    fi
}

if ! command -v socat >/dev/null 2>&1; then

    echo "  socat is required for TFSRun SSH tunneling."
    echo "  Installing..."

    install_pkg socat \
        || die "Could not auto-install socat. Install it manually and re-run."

    command -v socat >/dev/null 2>&1 \
        || die "socat installation failed."

fi

ok "socat available"

# ---------------------------------------------------------------------------
# 4. Ask for application name
# ---------------------------------------------------------------------------

HOSTNAME_LABEL_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'

echo

while true; do

    prompt_var "Enter application name: " APP_NAME

    if [[ "${APP_NAME}" =~ ${HOSTNAME_LABEL_RE} ]]; then
        break
    fi

    fail "Invalid application name."
    echo "  Use lowercase letters, numbers, and hyphens only."

done

SUBDOMAIN="${APP_NAME}.${BASE_DOMAIN}"

# ---------------------------------------------------------------------------
# 5. Ask for SSH username
# ---------------------------------------------------------------------------
#
# This is NOT a TFSRun-created user.
#
# It must already exist on the VM.
#
# Examples:
#
#   ubuntu
#   node
#   debian
#   ec2-user
#
# The user will ultimately run:
#
#   ssh <username>@<app>.tfsrun.cloud
#

echo

while true; do

    prompt_var "Enter SSH username on the VM: " SSH_USER

    if [[ -z "${SSH_USER}" ]]; then

        fail "SSH username cannot be empty."

        continue

    fi

    # Basic SSH username validation.
    #
    # Linux usernames commonly contain:
    #   letters
    #   numbers
    #   underscore
    #   hyphen
    #   dollar sign at the end
    #
    if [[ ! "${SSH_USER}" =~ ^[a-zA-Z_][a-zA-Z0-9_.@-]*\$?$ ]]; then

        fail "Invalid SSH username."

        continue

    fi

    break

done

# ---------------------------------------------------------------------------
# 6. Check control plane status
# ---------------------------------------------------------------------------

if command -v curl >/dev/null 2>&1; then

    echo
    echo "  Checking ${SUBDOMAIN}..."

    HTTP_CODE="$(
        curl -sS \
            -o /tmp/tfsrun_status.json \
            -w '%{http_code}' \
            "${TFSRUN_API_BASE}/subdomains/${APP_NAME}/status" \
            2>/dev/null || echo "000"
    )"

    case "${HTTP_CODE}" in

        200)

            CONNECTED="$(
                jq -r '.tunnel_connected // false' \
                /tmp/tfsrun_status.json \
                2>/dev/null || echo false
            )"

            if [[ "${CONNECTED}" == "true" ]]; then

                ok "Control plane confirms ${SUBDOMAIN} has an active tunnel"

            else

                warn "${SUBDOMAIN} is registered but its tunnel is not currently connected"

            fi

            ;;

        404)

            warn "${SUBDOMAIN} is not registered yet."
            warn "Run setup-vm.sh on the VM first."

            ;;

        000)

            warn "Could not reach the control plane."
            warn "Continuing with local SSH configuration."

            ;;

        *)

            warn "Unexpected control plane response: HTTP ${HTTP_CODE}"
            warn "Continuing with local SSH configuration."

            ;;

    esac

    rm -f /tmp/tfsrun_status.json

fi

# ---------------------------------------------------------------------------
# 7. Determine local user's SSH configuration directory
# ---------------------------------------------------------------------------
#
# The script itself runs under sudo, so SUDO_USER is the person who invoked
# sudo. That is the account whose ~/.ssh/config should be modified.
#

TARGET_USER="${SUDO_USER:-root}"

TARGET_HOME="$(
    getent passwd "${TARGET_USER}" |
    cut -d: -f6
)"

if [[ -z "${TARGET_HOME}" ]]; then
    TARGET_HOME="${HOME}"
fi

SSH_DIR="${TARGET_HOME}/.ssh"
SSH_CONFIG="${SSH_DIR}/config"

mkdir -p "${SSH_DIR}"

chmod 700 "${SSH_DIR}"

touch "${SSH_CONFIG}"

chmod 600 "${SSH_CONFIG}"

chown "${TARGET_USER}:${TARGET_USER}" \
    "${SSH_DIR}" \
    "${SSH_CONFIG}" \
    2>/dev/null || true

# ---------------------------------------------------------------------------
# 8. Create SSH configuration
# ---------------------------------------------------------------------------
#
# IMPORTANT:
#
# There is intentionally NO:
#
#   IdentityFile
#   IdentitiesOnly
#   ssh-keygen
#   authorized_keys
#   enrollment
#
# Password authentication is explicitly preferred.
#

BEGIN_MARK="# >>> TFSRun:${APP_NAME} >>>"
END_MARK="# <<< TFSRun:${APP_NAME} <<<"

NEW_BLOCK="$(cat <<EOF
${BEGIN_MARK}
Host ${SUBDOMAIN}
    User ${SSH_USER}
    PreferredAuthentications password,keyboard-interactive
    PubkeyAuthentication no
    PasswordAuthentication yes
    KbdInteractiveAuthentication yes
    ProxyCommand socat - PROXY:${FRPS_ADDR}:%h:%p,proxyport=${TCPMUX_PORT}
    ServerAliveInterval 30
${END_MARK}
EOF
)"

# ---------------------------------------------------------------------------
# 9. Replace existing TFSRun block or create a new one
# ---------------------------------------------------------------------------

if grep -qF "${BEGIN_MARK}" "${SSH_CONFIG}" 2>/dev/null; then

    TMP_CONFIG="$(mktemp)"

    awk \
        -v begin="${BEGIN_MARK}" \
        -v end="${END_MARK}" '

        $0 == begin {
            skip=1
        }

        !skip {
            print
        }

        $0 == end {
            skip=0
        }

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

chown "${TARGET_USER}:${TARGET_USER}" \
    "${SSH_CONFIG}" \
    2>/dev/null || true

# ---------------------------------------------------------------------------
# 10. Verify DNS
# ---------------------------------------------------------------------------

echo

echo "  Checking DNS resolution for ${FRPS_ADDR}..."

if command -v getent >/dev/null 2>&1 &&
   getent hosts "${FRPS_ADDR}" >/dev/null 2>&1; then

    ok "${FRPS_ADDR} resolves"

elif command -v host >/dev/null 2>&1 &&
     host "${FRPS_ADDR}" >/dev/null 2>&1; then

    ok "${FRPS_ADDR} resolves"

else

    warn "${FRPS_ADDR} did not resolve."

fi

# ---------------------------------------------------------------------------
# 11. Verify TCP connectivity to TFSRun ingress
# ---------------------------------------------------------------------------

echo "  Checking TCP connectivity to ${FRPS_ADDR}:${TCPMUX_PORT}..."

if timeout 5 \
    bash -c "cat < /dev/null > /dev/tcp/${FRPS_ADDR}/${TCPMUX_PORT}" \
    2>/dev/null; then

    ok "TFSRun ingress reachable on port ${TCPMUX_PORT}"

else

    warn "Could not reach ${FRPS_ADDR}:${TCPMUX_PORT}"
    warn "SSH will fail until this is reachable."

fi

# ---------------------------------------------------------------------------
# 12. Final summary
# ---------------------------------------------------------------------------

echo

banner "TFSRun SSH Client Setup Complete"

echo

echo "Application:"
echo "    ${APP_NAME}"

echo

echo "Hostname:"
echo "    ${SUBDOMAIN}"

echo

echo "SSH username:"
echo "    ${SSH_USER}"

echo

echo "Authentication:"
echo "    Password-based"
echo "    SSH keys required: No"

echo

echo "SSH configured:"
echo "    ssh ${SSH_USER}@${SUBDOMAIN}"

echo

echo "The VM must have an existing Linux user named '${SSH_USER}'."
echo "Use that user's existing password when SSH asks for it."

echo

echo "Example:"
echo "    ssh ${SSH_USER}@${SUBDOMAIN}"