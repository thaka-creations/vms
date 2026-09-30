#!/bin/bash

# Install a public SSH key for a user on this server and optionally
# disable password authentication.
# Run on the SERVER as root: sudo bash ssh_authorize.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

[[ $EUID -ne 0 ]] && { error "Run as root: sudo bash ssh_authorize.sh"; exit 1; }

# ------------------------------
# Inputs
# ------------------------------
read -rp "Username to authorize key for: " TARGET_USER
read -rp "Paste the public key (ssh-ed25519 ...): " PUB_KEY

id "$TARGET_USER" &>/dev/null || {
    error "User '$TARGET_USER' does not exist. Run create_user.sh first."
    exit 1
}

[[ "$PUB_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh[.]com|sk-ecdsa-sha2-nistp256@openssh[.]com)\ [A-Za-z0-9+/=]+(\ .*)?$ ]] \
    && ssh-keygen -l -f <(echo "$PUB_KEY") &>/dev/null || {
    error "Does not look like a valid public key."
    exit 1
}

# ------------------------------
# Install key
# ------------------------------
USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
SSH_DIR="${USER_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

# We run as root inside a directory the user controls. If .ssh or
# authorized_keys is a symlink, the append/chmod below would follow it and
# modify an arbitrary file (e.g. chmod 600 /etc/passwd). Refuse.
for p in "$SSH_DIR" "$AUTH_KEYS"; do
    [[ -L "$p" ]] && { error "$p is a symlink — refusing to follow it."; exit 1; }
done

log "Installing public key for ${TARGET_USER}..."
install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$SSH_DIR"

# Avoid duplicate entries
if grep -qF "$PUB_KEY" "$AUTH_KEYS" 2>/dev/null; then
    warning "Key already present in $AUTH_KEYS — skipping."
else
    echo "$PUB_KEY" >> "$AUTH_KEYS"
    success "Key added."
fi

chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEYS"
chown -h "${TARGET_USER}:${TARGET_USER}" "$SSH_DIR" "$AUTH_KEYS"

# ------------------------------
# Optionally harden SSH config
# ------------------------------
read -rp "Disable password authentication now? (yes/no): " DISABLE_PASS

if [[ "$DISABLE_PASS" == "yes" ]]; then
    # A drop-in named 00-* is read first; sshd keeps the FIRST value for each
    # keyword, so this wins over the main file and over cloud-init's
    # 50-cloud-init.conf (which ships PasswordAuthentication yes).
    DROPIN="/etc/ssh/sshd_config.d/00-key-only.conf"

    warning "Test your key login in a SEPARATE terminal before continuing."
    warning "If you are locked out, use the cloud console to re-enable password auth."
    read -rp "Confirmed key login works? (yes/no): " CONFIRMED
    [[ "$CONFIRMED" == "yes" ]] || { echo "Aborted — password auth unchanged."; exit 0; }

    grep -qE '^\s*Include\s+/etc/ssh/sshd_config.d/' /etc/ssh/sshd_config \
        || warning "sshd_config has no Include for sshd_config.d — ${DROPIN} will be ignored."

    install -d -m 755 /etc/ssh/sshd_config.d
    cat > "$DROPIN" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
EOF
    chmod 600 "$DROPIN"

    if ! sshd -t; then
        rm -f "$DROPIN"
        error "sshd config invalid — change reverted, ssh not restarted."
        exit 1
    fi

    systemctl restart ssh

    # Verify the effective config rather than trusting the edit
    if sshd -T 2>/dev/null | grep -qx 'passwordauthentication no'; then
        success "Password auth disabled. Root login disabled. Key-only access enforced."
    else
        error "sshd still reports password authentication enabled — check sshd_config.d overrides."
        exit 1
    fi
fi

echo ""
success "============================================================"
success " Authorized keys: ${AUTH_KEYS}"
success "============================================================"
