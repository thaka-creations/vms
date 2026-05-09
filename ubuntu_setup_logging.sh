#!/bin/bash
## auditd - for auditing system calls and file access
## apparmor - Restricts what programs can do (file access, network usage, capabilities)
## ossec-HIDS - Intrusion detection and log monitoring.
## lynis - Runs system scans to check for hardening, vulnerabilities, and misconfigurations and generates reports with recommendations
## OpenScap - Scans system against compliance standards (CIS, STIG, PCI-DSS, HIPAA)
## AIDE (Advanced Intrusion Detection Environment) - File Integrity Monitoring (FIM) tool 
set -e

echo "🚀 Starting Ubuntu maintenance script..."

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

backup_file() {
    local file="$1"
    local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
    
    if [[ -f "$file" ]]; then
        cp "$file" "$backup"
        info "Backed up $file to $backup"
    fi
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

update_system() {
    log "🛠️ Updating and upgrading system packages..."
    apt update
}

setup_auditd() {
    log "🔍 Setting up auditd for file integrity monitoring..."
    
    # Install auditd if not present
    if ! command -v auditctl >/dev/null 2>&1; then
        info "Installing auditd..."
        apt update && apt install -y auditd audispd-plugins
        success "auditd installed"
    else
        info "auditd is already installed"
    fi
    
    # Backup audit rules
    backup_file "/etc/audit/rules.d/audit.rules"
    backup_file "/etc/audit/audit.rules"
    
    # Create comprehensive audit rules
    local audit_rules="/etc/audit/rules.d/security-hardening.rules"
    
    info "Creating audit rules at $audit_rules"
    cat > "$audit_rules" << 'EOF'
# Security Hardening Audit Rules

# Delete all current rules
-D

# Set failure mode
-f 1

# Watches for critical files
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
-w /var/log/sudo.log -p wa -k sudo_log_file
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/nsswitch.conf -p wa -k identity
-w /etc/pam.conf -p wa -k identity
-w /etc/pam.d -p wa -k identity
-w /etc/security/opasswd -p wa -k identity
-w /etc/fstab -p wa -k filesystem_config
-w /var/run/utmp -p wa -k session
-w /var/log/wtmp -p wa -k session
-w /var/log/btmp -p wa -k session
-w /var/log/lastlog -p wa -k logins
-w /var/log/faillock/ -p wa -k logins
-w /etc/hosts -p wa -k network_env
-w /etc/hostname -p wa -k network_config
-w /etc/localtime -p wa -k time-change
-w /etc/selinux/ -p wa -k mac-policy
-w /usr/share/selinux/ -p wa -k mac-policy
-w /etc/apparmor/ -p wa -k mac_policy
-w /etc/apparmor.d/ -p wa -k mac_policy
-w /etc/ssh/sshd_config -p wa -k ssh_config
-w /boot -p wa -k boot_changes
-w /etc/crontab -p wa -k cron_changes
-w /etc/cron.d/ -p wa -k cron_changes
-w /var/spool/cron/ -p wa -k cron_changes
-w /sbin/insmod -p x -k modules
-w /sbin/rmmod -p x -k modules
-w /sbin/modprobe -p x -k modules
-w /sbin/modinfo -p x -k modules
-w /etc/issue -p wa -k system-locale
-w /etc/issue.net -p wa -k system-locale
-w /etc/netplan -p wa -k system-locale
-w /etc/networks -p wa -k system-locale

# Syscall auditing (64-bit)
-a always,exit -F arch=b64 -S execve -C euid!=uid -F auid!=unset -k user_actions
-a always,exit -F arch=b32 -C euid!=uid -F auid!=unset -S execve -k user_emulation
-a always,exit -F arch=b64 -C euid!=uid -F auid!=unset -S execve -k user_emulation
-a always,exit -F arch=b64 -S adjtimex,settimeofday -k time-change
-a always,exit -F arch=b64 -S sethostname,setdomainname -k system-locale
-a always,exit -F arch=b64 -S open,truncate,ftruncate,creat,openat,open_by_handle_at -F exit=-EACCES -k access
-a always,exit -F arch=b64 -S open,truncate,ftruncate,creat,openat,open_by_handle_at -F exit=-EPERM -k access
-a always,exit -F arch=b64 -S chmod,fchmod,fchmodat,setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b64 -S chown,fchown,lchown,fchownat -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b64 -S mount -F auid>=1000 -F auid!=unset -k mounts
-a always,exit -F arch=b64 -S setuid,setreuid,setresuid -k privilege
-a always,exit -F arch=b32 -S adjtimex,settimeofday -k time-change
-a always,exit -F arch=b32 -S clock_settime -F a0=0x0 -k time-change
-a always,exit -F arch=b64 -S clock_settime -F a0=0x0 -k time-change
-a always,exit -F arch=b32 -S sethostname,setdomainname -k system-locale
-a always,exit -F arch=b32 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b32 -S chown,fchown,lchown,fchownat -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b32 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b64 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b32 -S mount -F auid>=1000 -F auid!=unset -k mounts
-a always,exit -F arch=b32 -S unlink,unlinkat,rename,renameat -F auid>=1000 -F auid!=unset -k delete
-a always,exit -F arch=b64 -S unlink,unlinkat,rename,renameat -F auid>=1000 -F auid!=unset -k delete
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module,create_module,query_module -F auid>=1000 -F auid!=unset -k kernel_modules


# Path-based executions
-a always,exit -F path=/usr/bin/chcon -F perm=x -F auid>=1000 -F auid!=unset -k perm_chng
-a always,exit -F path=/usr/bin/setfacl -F perm=x -F auid>=1000 -F auid!=unset -k perm_chng
-a always,exit -F path=/usr/bin/chacl -F perm=x -F auid>=1000 -F auid!=unset -k perm_chng
-a always,exit -F path=/usr/sbin/usermod -F perm=x -F auid>=1000 -F auid!=unset -k usermod
-a always,exit -F path=/usr/bin/sudo -F perm=x -F auid>=1000 -F auid!=unset -k actions
-a always,exit -F path=/usr/bin/su -F perm=x -F auid>=1000 -F auid!=unset -k actions
-a always,exit -F path=/usr/bin/pkexec -F perm=x -F auid>=1000 -F auid!=unset -k actions
-a always,exit -F path=/usr/bin/kmod -F perm=x -F auid>=1000 -F auid!=unset -k kernel_modules


# Kernel modules (syscall auditing)
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module,create_module,query_module -k modules
-a always,exit -F arch=b64 -S init_module,delete_module -k module_load

# File access
-a always,exit -F arch=b32 -S creat,open,openat,truncate,ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=unset -k access
-a always,exit -F arch=b32 -S creat,open,openat,truncate,ftruncate -F exit=-EPERM -F auid>=1000 -F auid!=unset -k access
-a always,exit -F arch=b64 -S creat,open,openat,truncate,ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=unset -k access
-a always,exit -F arch=b64 -S creat,open,openat,truncate,ftruncate -F exit=-EPERM -F auid>=1000 -F auid!=unset -k access


# Immutable rules
-e 2

EOF
    
    # Start and enable auditd
    systemctl enable auditd
    systemctl restart auditd
    
    success "auditd configured and started"
    info "Audit rules created at $audit_rules"
    info "View audit logs with: ausearch -k <key_name>"
}

## Set up ossec agents
setup_ossec_hids(){
    log "🛠️ Installing ossec-hids."
    wget -q -O - https://updates.atomicorp.com/installers/atomic | sudo bash
    apt-get update
    apt-get install ossec-hids-agent
}

## Set up lynis
setup_lynis(){
    log "🛠️ Installing Lynis"
    apt update
    apt install lynis
    lynis audit system

}
## Set up OpenScap
setup_openscap(){
    log "🛠️ Installing Openscap"
    apt update
    apt install openscap-scanner 
    # wget https://github.com/ComplianceAsCode/content/releases/download/v0.1.78/scap-security-guide-0.1.78.tar.gz
    # wget https://github.com/ComplianceAsCode/content/releases/download/v0.1.78/scap-security-guide-0.1.78.tar.gz.sha512
    # sha512sum -c scap-security-guide-0.1.78.tar.gz.sha512
    # tar -xvzf scap-security-guide-0.1.78.tar.gz

    # sudo mkdir -p /usr/share/xml/scap/ssg/content
    # sudo cp build/ssg-ubuntu2204-ds.xml /usr/share/xml/scap/ssg/content/
    # oscap xccdf eval --profile PROFILE_NAME --results results.xml --report report.html /path/to/scap-content.xml
    # oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_cis_level1_server --results results.xml --report report.html /usr/share/xml/scap/ssg/content/ssg-ubuntu2404-ds.xml
    # oscap-ssh --sudo user1@192.168.50.180 2004 info  /usr/share/xml/scap/ssg/content/ssg-ubuntu2404-ds.xml
    # export SSH_ADDITIONAL_OPTIONS="-i ~/.ssh/prod_key"
    # oscap-ssh --sudo user1@192.168.50.180 2004 xccdf eval --profile xccdf_org.ssgproject.content_profile_cis_level1_server --results results.xml --report report_50180.html /usr/share/xml/scap/ssg/content/ssg-ubuntu2404-ds.xml
}
install_AIDE(){
  apt install -y aide aide-common
  aideinit
  mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
  aide --config /etc/aide/aide.conf --check
  success "Installed AIDE"
}

mount_tmp(){
  backup_file "/etc/fstab"
  FSTAB="/etc/fstab"
  ENTRY="tmpfs /tmp tmpfs defaults,nodev,nosuid,noexec,size=2G 0 0"
  VAR_ENTRY="tmpfs /var/tmp tmpfs defaults,nodev,nosuid,noexec,size=2G 0 0"
  # Check if the entry already exists
  if grep -q "^tmpfs\s\+/tmp\s\+tmpfs" "$FSTAB"; then
    info "An entry for /tmp already exists in $FSTAB. Skipping..."
  else
    info "Adding /tmp tmpfs entry to $FSTAB"
    echo "$ENTRY" | sudo tee -a "$FSTAB"
  fi
  if grep -q "^tmpfs\s\+/var/tmp\s\+tmpfs" "$FSTAB"; then
    info "An entry for /var/tmp already exists in $FSTAB. Skipping..."
  else
    info "Adding /var/tmp tmpfs entry to $FSTAB"
    echo "$VAR_ENTRY" | sudo tee -a "$FSTAB"
  fi
  systemctl daemon-reload
  mount -a
  if mount | grep -q /var/tmp; then
    success "/var/tmp is mounted"
  else
    error "/var/tmp is NOT mounted"
  fi
}

install_clamav(){
  apt install clamav
  freshclam
  clamscan -r /
}

disable_usb(){
  log "Disabling usb"
  echo "blacklist usb-storage" >> /etc/modprobe.d/blacklist.conf
}

disable_services() {
    log "Disabling unnecessary services..."

    local services_to_disable=(
        "bluetooth"
        "cups"
        "avahi-daemon"
        "rpcbind"
        "nfs-client.target"
        "remote-fs.target"
    )

    for service in "${services_to_disable[@]}"; do
        if systemctl is-enabled "$service" &>/dev/null; then
            systemctl disable --now "$service" 2>/dev/null || true
            log "Disabled $service"
        fi
    done
}

journald_rsyslog(){
    CONF_FILE="/etc/systemd/journald.conf"
    backup_file $CONF_FILE
    if grep -q '^ForwardToSyslog' "$CONF_FILE"; then
        sed -i 's/^ForwardToSyslog.*/ForwardToSyslog=yes/' "$CONF_FILE"
    else
        echo "ForwardToSyslog=yes" >> "$CONF_FILE"
    fi
    log "restarting systemd-journald"
    systemctl restart systemd-journald

}

configure_logrotate() {
    log "Configuring logrotate..."
    if [[ -f "/etc/logrotate.d/security" ]]; then
        backup_file "/etc/logrotate.d/security"
        log "Backed up /etc/logrotate.d/security"
    fi
    if [[ -f "/etc/logrotate.d/auditd" ]]; then
        backup_file "/etc/logrotate.d/auditd"
        log "Backed up /etc/logrotate.d/auditd"
    fi
    cat > /etc/logrotate.d/security << 'EOF'
/var/log/secure {
    daily
    rotate 90
    compress
    delaycompress
    missingok
    notifempty
    create 0600 root root
}
EOF
    cat > /etc/logrotate.d/auditd << 'EOF'
/var/log/audit/audit.log {
    daily
    rotate 90
    compress
    delaycompress
    missingok
    notifempty
    create 0600 root root
    postrotate
        /usr/bin/killall -SIGUSR1 auditd > /dev/null 2>&1 || true
    endscript
}
EOF
    success "Logrorate for auditd logs "
}

safe_chmod(){
    local mode="$1"
    local target="$2"
    if [ -e "$target" ]; then
        chmod "$mode" "$target"
    else
        warning "Skipping chmod $mode $target — path does not exist"
    fi
}

set_file_permissions(){
    safe_chmod 0600 /etc/ssh/sshd_config
    safe_chmod 0600 /etc/shadow
    safe_chmod 0600 /etc/gshadow
    safe_chmod 0644 /etc/passwd
    safe_chmod 0644 /etc/group
    safe_chmod 0600 /etc/crontab
    safe_chmod 0700 /etc/cron.d
    safe_chmod 0700 /etc/cron.daily
    safe_chmod 0700 /etc/cron.hourly
    safe_chmod 0700 /etc/cron.monthly
    safe_chmod 0700 /etc/cron.weekly
    safe_chmod 700  /etc/audit
    safe_chmod 700  /etc/audit/plugins.d
    safe_chmod 700  /etc/audit/rules.d
    safe_chmod 600  /etc/audit/*.conf
    safe_chmod 600  /etc/audit/*.rules
    safe_chmod 600  /etc/audit/rules.d/*.rules
    safe_chmod 700  /sbin/auditctl
    safe_chmod 700  /sbin/aureport
    safe_chmod 700  /sbin/ausearch
    safe_chmod 700  /sbin/autrace
    safe_chmod 700  /sbin/auditd
    safe_chmod 700  /sbin/augenrules
    safe_chmod 600  /etc/security/opasswd
    if [ -f /etc/security/opasswd ]; then
        chown root:root /etc/security/opasswd
    fi
}


check_root
update_system
setup_auditd
disable_usb
#setup_lynis
#setup_ossec_hids
#setup_openscap
#install_clamav
#install_AIDE
mount_tmp
disable_services
journald_rsyslog
configure_logrotate
set_file_permissions

