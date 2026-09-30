#!/bin/bash

set -euo pipefail

# ------------------------------
# Create a new sudo user with SSH key access
# Run as root or with sudo
# ------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash create_user.sh" >&2
  exit 1
fi

read -rp "Enter new username: " NEW_USER

if ! [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  echo "Invalid username '$NEW_USER' (lowercase letters, digits, _ or -; max 32 chars)."
  exit 1
fi

if id "$NEW_USER" &>/dev/null; then
  echo "User '$NEW_USER' already exists."
  exit 1
fi

# Create user with home directory
useradd -m -s /bin/bash "$NEW_USER"
echo "Created user: $NEW_USER"

# Set password
echo "Set a password for $NEW_USER:"
passwd "$NEW_USER"

# Add to sudo group
usermod -aG sudo "$NEW_USER"
echo "Added $NEW_USER to sudo group."

# Set up SSH directory
USER_HOME=$(getent passwd "$NEW_USER" | cut -d: -f6)
SSH_DIR="$USER_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "$SSH_DIR"
install -m 600 -o "$NEW_USER" -g "$NEW_USER" /dev/null "$AUTH_KEYS"

# Optionally add a public key
read -rp "Paste your SSH public key (or press Enter to skip): " PUB_KEY
if [ -n "$PUB_KEY" ]; then
  if ssh-keygen -l -f <(echo "$PUB_KEY") &>/dev/null; then
    echo "$PUB_KEY" >> "$AUTH_KEYS"
    echo "Public key added to $AUTH_KEYS"
  else
    echo "That is not a valid SSH public key — skipped. Add one later with ssh_authorize.sh."
  fi
fi

echo ""
echo "Done. Test login with:"
echo "  ssh -p <port> $NEW_USER@<vm-ip>"
