#!/bin/bash

# Generate an ed25519 SSH key pair on your local machine.
# Run: bash ssh_keygen.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }

read -rp "Key name [default: id_ed25519]: " KEY_NAME
read -rp "Comment / label (e.g. you@host): " KEY_COMMENT

KEY_NAME=${KEY_NAME:-id_ed25519}
[[ "$KEY_NAME" =~ ^[A-Za-z0-9._-]+$ && "$KEY_NAME" != .* ]] || {
    error "Key name may only contain letters, digits, '.', '_' and '-'."
    exit 1
}
KEY_PATH="$HOME/.ssh/${KEY_NAME}"

if [[ -f "$KEY_PATH" ]]; then
    warning "Key already exists at $KEY_PATH"
    read -rp "Overwrite? (yes/no): " CONFIRM
    [[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }
fi

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# No -N "": ssh-keygen prompts for a passphrase. An unencrypted private key
# grants server access to anyone who copies the file (backups, iCloud sync…).
log "You will be asked for a passphrase — use one (ssh-agent / Keychain caches it)."
ssh-keygen -t ed25519 -a 100 -C "${KEY_COMMENT}" -f "${KEY_PATH}"
chmod 600 "${KEY_PATH}"
chmod 644 "${KEY_PATH}.pub"

echo ""
success "============================================================"
success " Private key: ${KEY_PATH}"
success " Public key:  ${KEY_PATH}.pub"
success "============================================================"
echo ""
log "Public key:"
cat "${KEY_PATH}.pub"
