#!/bin/bash

# Completely removes MongoDB: packages, data, logs, config, repo files.
# Run on Ubuntu as root. DATA WILL BE PERMANENTLY DELETED.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

[[ $EUID -ne 0 ]] && { echo -e "${RED}[ERROR]${NC} Run as root: sudo bash mongo_uninstall.sh" >&2; exit 1; }

warning "This will permanently delete all MongoDB data, config, and packages."
read -rp "Type YES to confirm: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Aborted."; exit 0; }

log "Stopping and disabling mongod..."
systemctl stop  mongod  2>/dev/null || true
systemctl disable mongod 2>/dev/null || true

log "Removing MongoDB packages..."
apt-get purge -y \
    mongodb-org \
    mongodb-org-server \
    mongodb-org-mongos \
    mongodb-org-database \
    mongodb-org-database-tools-extra \
    mongodb-mongosh \
    2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

log "Removing data, logs, config, and repo files..."
rm -rf /var/lib/mongodb
rm -rf /var/log/mongodb
rm -f  /etc/mongod.conf
rm -rf /etc/mongod
rm -f  /etc/apt/sources.list.d/mongodb-org-*.list
rm -f  /usr/share/keyrings/mongodb-server-*.gpg

apt-get update

success "MongoDB fully removed."
