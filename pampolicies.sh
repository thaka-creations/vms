#!/bin/bash

# PAM Password Policy Configuration Script
# This script configures password policies without breaking sudo
# Must be run as root

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root"
   exit 1
fi

# Backup function
backup_file() {
    local file=$1
    if [[ -f "$file" ]]; then
        cp "$file" "${file}.backup.$(date +%Y%m%d_%H%M%S)"
        log "Backed up $file"
    fi
}

# 35671: Install libpam-pwquality
log "Installing libpam-pwquality..."
apt-get update -qq
apt-get install -y libpam-pwquality

# Backup PAM configuration files
log "Backing up PAM configuration files..."
backup_file /etc/pam.d/common-auth
backup_file /etc/pam.d/common-account
backup_file /etc/pam.d/common-password
backup_file /etc/pam.d/common-session
backup_file /etc/security/faillock.conf
backup_file /etc/security/pwquality.conf

# 35672: Ensure pam_unix module is enabled
log "Configuring pam_unix module..."

cat > /etc/pam.d/common-account << 'EOF'
# Account management via Unix and faillock
account [success=1 new_authtok_reqd=done default=ignore]        pam_unix.so
password requisite pam_pwquality.so retry=3
account requisite                       pam_deny.so
account required                        pam_permit.so
account required                        pam_faillock.so

EOF

# --- common-password ---
cat > /etc/pam.d/common-password << 'EOF'
password requisite                  pam_pwquality.so retry=3
password requisite                   pam_pwhistory.so remember=5 use_authtok enforce_for_root
password [success=1 default=ignore] pam_unix.so use_authtok obscure yescrypt 
password requisite                  pam_deny.so
password required                   pam_permit.so

EOF


cat > /etc/pam.d/common-auth << 'EOF'
# Standard Unix authentication with faillock
auth required                           pam_faillock.so preauth silent deny=5 unlock_time=900 even_deny_root
auth [success=2 default=ignore]         pam_unix.so try_first_pass
auth [success=1 default=die]            pam_faillock.so authfail
auth requisite                          pam_deny.so
auth required                           pam_permit.so
auth optional                           pam_cap.so
auth sufficient                         pam_faillock.so authsucc
EOF

cat > /etc/security/faillock.conf << "EOF"
deny = 5
unlock_time = 900
even_deny_root
root_unlock_time = 900
dir = /var/run/faillock
silent
audit
fail_interval = 900
EOF

cat > /etc/security/pwquality.conf << "EOF"
minlen = 14
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
difok = 7
maxrepeat = 3
maxsequence = 3
minclass = 4
maxclassrepeat = 4
dictcheck = 1
usercheck = 1
enforce_for_root
retry = 3
EOF
