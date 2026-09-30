#!/bin/bash

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "❌ Run as root: sudo bash ubuntu_hardening_v1.sh" >&2
  exit 1
fi

echo "🚀 Starting Ubuntu maintenance script..."

# ------------------------------
# System update and upgrade
# ------------------------------
echo "🛠️ Updating and upgrading system packages..."
sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove -y
sudo apt autoclean -y
sudo apt clean

#remove unnecessary packages
sudo apt purge -y vsftpd telnet apport inetutils-telnet || true

echo "✅ System packages updated."

# ------------------------------
# Enable Automatic Security Updates
# ------------------------------
echo "🔐 Configuring automatic security updates..."
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades
sudo sed -i 's|//\s*"\${distro_id}:\${distro_codename}-security";|"\${distro_id}:\${distro_codename}-security";|' /etc/apt/apt.conf.d/50unattended-upgrades

cat <<EOF | sudo tee /etc/apt/apt.conf.d/10periodic
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
echo "✅ Automatic security updates enabled."

# ------------------------------
# Firmware updates (UEFI only)
# ------------------------------
echo "🧬 Checking for firmware updates..."
if [ -d /sys/firmware/efi ]; then
  sudo apt install -y fwupd
  sudo fwupdmgr refresh
  sudo fwupdmgr get-updates
  sudo fwupdmgr update -y
  echo "⚠️ Firmware updated if any were found. Reboot recommended."
else
  echo "⚠️ Legacy BIOS detected — skipping firmware updates (UEFI required)."
fi
echo "✅ Firmware update check complete."


# ------------------------------
# Enforce strong password policy
# ------------------------------
# echo "🔐 Setting strong password policy (min 12 chars + complexity)..."
# sudo cp /etc/security/pwquality.conf /etc/security/pwquality.conf.bak || true
# sudo bash -c 'cat > /etc/security/pwquality.conf <<EOF
# minlen = 12
# dcredit = -1
# ucredit = -1
# lcredit = -1
# ocredit = -1
# EOF'

# sudo cp /etc/pam.d/common-password /etc/pam.d/common-password.bak || true
# if grep -q pam_pwquality.so /etc/pam.d/common-password; then
#   sudo sed -i 's/^password.*pam_pwquality.so.*/password requisite pam_pwquality.so retry=3/' /etc/pam.d/common-password
# else
#   sudo sed -i '/^password.*pam_unix.so/a password requisite pam_pwquality.so retry=3' /etc/pam.d/common-password
# fi
# echo "✅ Strong password policy configured."

# ------------------------------
# SSH CONFIGS
# ------------------------------

read -rp "Enter custom SSH port [default: 2004]: " SSH_PORT
SSH_PORT=${SSH_PORT:-2004}
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
  echo "❌ Invalid SSH port: $SSH_PORT" >&2
  exit 1
fi

# Password auth is disabled below — refuse to continue unless at least one
# non-root user has an authorized key, otherwise we lock ourselves out.
if [[ -z "$(find /home -mindepth 3 -maxdepth 3 -path '*/.ssh/authorized_keys' -size +0 -print -quit 2>/dev/null)" ]]; then
  echo "❌ No /home/*/.ssh/authorized_keys found. Add your key first (ssh_authorize.sh)." >&2
  exit 1
fi

echo "🔐 Configuring SSH settings..."

sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak || true

# Create SSH config
# sshd uses the FIRST value it sees for each keyword, so the Include of
# sshd_config.d goes at the END — otherwise cloud-init's 50-cloud-init.conf
# (PasswordAuthentication yes) silently overrides the settings below.
cat << EOF > /etc/ssh/sshd_config
Port $SSH_PORT
AddressFamily inet
ListenAddress 0.0.0.0

# SSH host keys
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

# Ciphers and keying
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512

# Logging
SyslogFacility AUTHPRIV
LogLevel INFO

# Authentication
HostbasedAuthentication no
PasswordAuthentication no
PermitRootLogin no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
AuthenticationMethods publickey
KbdInteractiveAuthentication no
UsePAM yes

# Session settings
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 60
MaxAuthTries 3
MaxSessions 2
MaxStartups 10:30:60

# Misc
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
PermitUserEnvironment no
PrintMotd no
PermitTTY yes
PermitUserRC no
IgnoreRhosts yes
Subsystem sftp	/usr/lib/openssh/sftp-server

Include /etc/ssh/sshd_config.d/*.conf
EOF
chmod 600 /etc/ssh/sshd_config

# Validate before restarting — a bad config would leave sshd down.
if ! sshd -t; then
  echo "❌ sshd config invalid — restoring backup." >&2
  cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
  exit 1
fi

# Open the new SSH port BEFORE restarting sshd on it, so an already-active
# UFW never cuts us off.
ufw allow "${SSH_PORT}/tcp" || true

# Restart SSH with correct service name
# (Ubuntu 22.10+ uses socket activation; restart the socket too if present)

echo "🔁 Restarting SSH service..."
sudo systemctl daemon-reload
systemctl is-enabled ssh.socket &>/dev/null && sudo systemctl restart ssh.socket || true
sudo systemctl restart ssh
echo "✅ SSH configuration applied and service restarted."



echo "⏰ Setting session timeout (5 minutes)..."

# Set TMOUT for shell sessions
if ! grep -q '^export TMOUT=' /etc/profile; then
  echo 'export TMOUT=300' | sudo tee -a /etc/profile
  echo 'readonly TMOUT' | sudo tee -a /etc/profile
fi

echo "✅ Session timeout set."


# ------------------------------
# Lock user after 5 failed attempts (unlock after 10 mins)
# Configure pa_faillock for blocking user accounts
# ------------------------------

# echo "🔐 Configuring account lockout policy..."
# sudo cp /etc/pam.d/common-auth /etc/pam.d/common-auth.bak || true
# sudo cp /etc/pam.d/common-account /etc/pam.d/common-account.bak || true

# if ! grep -q "pam_faillock.so preauth" /etc/pam.d/common-auth; then
#   sudo sed -i '/pam_unix.so/i auth required pam_faillock.so preauth silent deny=5 unlock_time=600 fail_interval=600' /etc/pam.d/common-auth
#   echo "[+] Inserted preauth rule before pam_unix.so"
# fi
# if ! grep -q "pam_faillock.so authfail" /etc/pam.d/common-auth; then
#   sudo sed -i '/pam_unix.so/a auth [default=die] pam_faillock.so authfail deny=5 unlock_time=600 fail_interval=600' /etc/pam.d/common-auth
#   echo "[+] Inserted authfail rule after pam_unix.so"
# fi
# if ! grep -q "pam_faillock.so" /etc/pam.d/common-account; then
#   sudo sed -i '/pam_unix.so/a account required pam_faillock.so' /etc/pam.d/common-account
#   echo "[+] Added pam_faillock.so after pam_unix.so"
# fi
# echo "✅ Account lockout configured."

#Configure fail2ban for locking IP addresses

echo "Installing Fail2Ban..."
sudo apt install -y fail2ban
JAIL_CONF="/etc/fail2ban/jail.local"

#backup
sudo cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.bak || true

# Backup existing config if present

echo "Writing new jail.local..."
# port must be the real SSH port — "ssh" means 22, so bans on a custom
# port would block the wrong port and never take effect.
cat > "$JAIL_CONF" << EOF
[DEFAULT]
bantime  = 1h
findtime  = 10m
maxretry = 3
backend = systemd

[sshd]
enabled = true
port    = ${SSH_PORT}
logpath = %(sshd_log)s
maxretry = 3
EOF

echo "Restarting and enabling fail2ban..."
systemctl enable fail2ban
systemctl restart fail2ban
echo "fail2ban restarted and enabled"


# ------------------------------
# Enable UFW firewall
# ------------------------------
echo "🛡️ Enabling UFW firewall..."
sudo ufw default deny incoming
sudo ufw default allow outgoing
# Allow (rate-limited) SSH BEFORE enabling, or the enable drops our session.
sudo ufw limit "${SSH_PORT}/tcp"
sudo ufw --force enable
echo "✅ UFW enabled."


# ------------------------------
# Disable IPv6 system-wide
# ------------------------------
# ------------------------------
# Network hardening: prevent IP spoofing, SYN floods, block ICMP redirects
# ------------------------------
#Backup systctl.config

sudo cp /etc/sysctl.conf /etc/sysctl.conf.bak || true


echo "🚫 Disabling IPv6..."
echo "🛡️ Applying network hardening..."

sudo bash -c 'cat > /etc/sysctl.conf' <<EOF

#Disable ipv6
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1

# Prevent IP spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv6.conf.lo.disable_ipv6=1


# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_fin_timeout = 15

# Block ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Other
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
fs.suid_dumpable = 0

# Kernel info leaks / local privilege escalation surface
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2

EOF
# Unknown keys on older kernels must not abort the run under set -e
sudo sysctl -p || true

echo "✅ IPv6 disabled."
echo "✅ Network hardening applied."


# ------------------------------
# Kernel Hardening
# ------------------------------

echo 2 > /proc/sys/kernel/randomize_va_space
# echo "kernel.modules_disabled=1" >> /etc/sysctl.conf disables docker

echo "✅ Kernel hardening done.."
# ------------------------------
# Enable kernel ASLR
# ------------------------------
echo "🔐 Enabling Kernel ASLR..."
sudo sed -i '/^kernel.randomize_va_space/d' /etc/sysctl.conf
echo "kernel.randomize_va_space = 2" | sudo tee -a /etc/sysctl.conf
sudo sysctl -w kernel.randomize_va_space=2
echo "✅ Kernel ASLR enabled."

# ------------------------------
# Restrict kernel module loading
# ------------------------------
echo "🔒 Restricting kernel module loading..."
if ! grep -q "module.sig_enforce=1" /etc/default/grub; then
  sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT/ s/"$/ module.sig_enforce=1"/' /etc/default/grub
  sudo update-grub
fi
# Block rarely-used filesystems and network protocols (CIS 1.1.1 / 3.4) —
# historically a common source of kernel privilege-escalation bugs.
# ("install module /bin/false" blocked a module literally named "module".)
rm -f /etc/modprobe.d/disable-modules.conf
{
  for m in cramfs freevxfs jffs2 hfs hfsplus udf dccp sctp rds tipc; do
    echo "install $m /bin/false"
    echo "blacklist $m"
  done
} | sudo tee /etc/modprobe.d/cis-disable-modules.conf >/dev/null
echo "✅ Kernel module loading restricted (reboot needed)."

# ------------------------------
# # Disable core dumps
# # ------------------------------

#configure_limts() {
echo "🚫 Disabling core dumps..."
LIMITS_CONF="/etc/security/limits.conf"
echo "configuring resource limits"
sudo cp /etc/security/limits.conf /etc/security/limits.conf.bak || true
cat << 'EOF' > "$LIMITS_CONF" 
* soft core 0
* hard core 0
EOF
echo "✅ Core dumps disabled."
                                                           
# ------------------------------
# Limit process privileges (enable AppArmor)

# ------------------------------
echo "🔐 Enabling and enforcing AppArmor..."

sudo apt install -y apparmor-utils apparmor-profiles
sudo systemctl enable apparmor
sudo systemctl start apparmor
# Only profile files (not abstractions/, tunables/ …); one bad profile
# must not abort the rest of the hardening run.
find /etc/apparmor.d -maxdepth 1 -type f -exec aa-enforce {} + || true
echo "✅ AppArmor enabled and profiles enforced."

# ------------------------------
# Timezone and time sync
# ------------------------------
echo "⏰ Setting timezone to East Africa Time (EAT) and enabling time synchronization..."
sudo timedatectl set-timezone Africa/Nairobi
# Some images (Ubuntu 25.10+, many cloud images) ship chrony instead of
# systemd-timesyncd — the two conflict, so use whichever is present and
# only install timesyncd when neither is.
if [[ -n "$(systemctl list-unit-files chrony.service --no-legend 2>/dev/null)" ]]; then
  sudo systemctl enable --now chrony
else
  if [[ -z "$(systemctl list-unit-files systemd-timesyncd.service --no-legend 2>/dev/null)" ]]; then
    sudo apt install -y systemd-timesyncd
  fi
  sudo systemctl enable --now systemd-timesyncd
fi
sudo timedatectl set-ntp true
echo "✅ Timezone set to EAT and time synchronization enabled."

# ------------------------------
# Disable Bash history for all users
# ------------------------------
# Disabling history destroys the record of what an intruder (or an admin)
# ran. Keep it, timestamped; commands typed with a leading space are not
# recorded, so secrets can be kept out deliberately.
echo "📝 Configuring timestamped Bash history for all users..."
sed -i '/^export HISTSIZE=0$/d; /^export HISTFILESIZE=0$/d; /^unset HISTFILE$/d' /etc/profile
cat > /etc/profile.d/99-history.sh <<'EOF'
export HISTTIMEFORMAT='%F %T '
export HISTCONTROL=ignorespace
export HISTSIZE=10000
export HISTFILESIZE=10000
shopt -s histappend
EOF
chmod 644 /etc/profile.d/99-history.sh
echo "✅ Bash history timestamped (prefix a command with a space to keep it out)."

echo "🎉 VM HARDENING complete -REBOOT TO apply changes!"
