#!/bin/bash

set -e

# ------------------------------
# Create a new sudo user with SSH key access
# Run as root or with sudo
# ------------------------------

read -p "Enter new username: " NEW_USER

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
SSH_DIR="/home/$NEW_USER/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
chown -R "$NEW_USER:$NEW_USER" "$SSH_DIR"

# Optionally add a public key
read -p "Paste your SSH public key (or press Enter to skip): " PUB_KEY
if [ -n "$PUB_KEY" ]; then
  echo "$PUB_KEY" >> "$AUTH_KEYS"
  echo "Public key added to $AUTH_KEYS"
fi

echo ""
echo "Done. Test login with:"
echo "  ssh -p <port> $NEW_USER@<vm-ip>"
