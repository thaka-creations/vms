#!/bin/bash

# PostgreSQL backups with pgBackRest to Cloudflare R2 (S3-compatible).
# Weekly full + daily differential backups, continuous WAL archiving
# (point-in-time recovery), AES-256 encrypted before upload.
# Run as root after pg_setup.sh. Safe to re-run.

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

[[ $EUID -ne 0 ]] && { error "Run as root: sudo bash pg_backup_setup.sh"; exit 1; }

STANZA="${STANZA:-main}"
PGBR_CONF="/etc/pgbackrest/pgbackrest.conf"
CIPHER_FILE="/root/.pgbackrest_cipher.env"
HC_FILE="/etc/pgbackrest/healthcheck.env"

# ------------------------------
# Inputs
# ------------------------------
detect_cluster() {
    local line
    line=$(pg_lsclusters --no-header 2>/dev/null | awk '$2=="main"' | sort -k1,1nr | head -1)
    [[ -n "$line" ]] || { error "No 'main' PostgreSQL cluster found. Run pg_setup.sh first."; exit 1; }
    PG_VERSION=$(awk '{print $1}' <<< "$line")
    PG_PORT=$(awk '{print $3}' <<< "$line")
    PG_DATA=$(awk '{print $6}' <<< "$line")
    PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/main"
}

read_inputs() {
    if [[ -f "$PGBR_CONF" ]] && [[ -z "${RECONFIGURE:-}" ]]; then
        log "$PGBR_CONF exists; keeping its R2 settings (set RECONFIGURE=1 to replace them)."
        return
    fi
    [[ -n "${R2_ACCOUNT_ID:-}" ]]        || read -rp  "Cloudflare account ID: "            R2_ACCOUNT_ID
    [[ -n "${R2_BUCKET:-}" ]]            || read -rp  "R2 bucket name: "                   R2_BUCKET
    [[ -n "${R2_ACCESS_KEY_ID:-}" ]]     || read -rp  "R2 access key ID: "                 R2_ACCESS_KEY_ID
    [[ -n "${R2_SECRET_ACCESS_KEY:-}" ]] || { read -rsp "R2 secret access key: "          R2_SECRET_ACCESS_KEY; echo; }
    [[ -n "${S3_ENDPOINT:-}" ]]          || read -rp  "R2 jurisdiction (blank = default, eu, fedramp): " R2_JURISDICTION
    [[ -n "${REPO_PATH:-}" ]]            || read -rp  "Path inside the bucket [default: /pgbackrest/$(hostname -s)]: " REPO_PATH
    [[ -n "${HC_URL+x}" ]]               || read -rp  "Healthcheck URL for backups (optional, e.g. https://hc-ping.com/<uuid>): " HC_URL
    [[ -n "${HC_RESTORE_URL+x}" ]]       || read -rp  "Healthcheck URL for the monthly restore test (optional): " HC_RESTORE_URL
    REPO_PATH="${REPO_PATH:-/pgbackrest/$(hostname -s)}"
    S3_ENDPOINT="${S3_ENDPOINT:-${R2_ACCOUNT_ID}${R2_JURISDICTION:+.${R2_JURISDICTION}}.r2.cloudflarestorage.com}"

    [[ "$R2_BUCKET" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || { error "Invalid bucket name."; exit 1; }
    [[ -n "$R2_ACCESS_KEY_ID" && -n "$R2_SECRET_ACCESS_KEY" ]] || { error "R2 credentials are required."; exit 1; }
}

# ------------------------------
# Install pgBackRest (PGDG repo, added by pg_setup.sh)
# ------------------------------
install_pgbackrest() {
    if command -v pgbackrest >/dev/null; then
        log "pgBackRest $(pgbackrest version | awk '{print $2}') already installed."
        return
    fi
    log "Installing pgBackRest..."
    apt-get update -qq
    apt-get install -y -qq pgbackrest curl
    success "pgBackRest $(pgbackrest version | awk '{print $2}') installed"
}

# ------------------------------
# Repository config
# The cipher passphrase is generated once and never changes: every backup in
# the bucket is encrypted with it. Losing it makes the backups unreadable.
# ------------------------------
write_config() {
    install -d -o postgres -g postgres -m 750 /var/log/pgbackrest /var/spool/pgbackrest /var/lib/pgbackrest
    install -d -o root -g postgres -m 750 /etc/pgbackrest

    if [[ ! -f "$CIPHER_FILE" ]]; then
        ( umask 077; echo "PGBACKREST_CIPHER_PASS=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 64)" > "$CIPHER_FILE" )
        warning "New backup encryption passphrase saved to $CIPHER_FILE."
        warning "COPY IT OFF THIS SERVER NOW (password manager). Without it, no backup can be restored."
    fi
    # shellcheck disable=SC1090
    source "$CIPHER_FILE"

    [[ -f "$PGBR_CONF" ]] && [[ -z "${RECONFIGURE:-}" ]] && return

    ( umask 027; : > "$PGBR_CONF" )
    cat > "$PGBR_CONF" <<EOF
# Managed by pg_backup_setup.sh. Contains secrets: root:postgres 0640.
[global]
repo1-type=s3
repo1-s3-endpoint=${S3_ENDPOINT}
repo1-s3-region=auto
repo1-s3-bucket=${R2_BUCKET}
repo1-s3-key=${R2_ACCESS_KEY_ID}
repo1-s3-key-secret=${R2_SECRET_ACCESS_KEY}
repo1-s3-uri-style=path
repo1-path=${REPO_PATH}
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=${PGBACKREST_CIPHER_PASS}
repo1-retention-full-type=count
repo1-retention-full=4
repo1-retention-diff=7
repo1-bundle=y
repo1-block=y
${EXTRA_REPO_OPTS:-}
compress-type=zst
compress-level=3
process-max=2
start-fast=y
delta=y

archive-async=y
spool-path=/var/spool/pgbackrest
archive-push-queue-max=32GiB

log-path=/var/log/pgbackrest
log-level-console=info
log-level-file=detail

[${STANZA}]
pg1-path=${PG_DATA}
pg1-port=${PG_PORT}
pg1-socket-path=/var/run/postgresql
EOF
    chown root:postgres "$PGBR_CONF"
    chmod 640 "$PGBR_CONF"

    ( umask 027; printf 'HC_URL=%s\nHC_RESTORE_URL=%s\n' "${HC_URL:-}" "${HC_RESTORE_URL:-}" > "$HC_FILE" )
    chown root:postgres "$HC_FILE"
    success "Wrote $PGBR_CONF"
}

# ------------------------------
# WAL archiving. archive_mode needs a restart (a few seconds of downtime;
# apps reconnect). archive_command and archive_timeout only need a reload.
# ------------------------------
configure_archiving() {
    local DROPIN="$PG_CONF_DIR/conf.d/pgbackrest.conf"
    install -d -o postgres -g postgres "$PG_CONF_DIR/conf.d"
    cat > "$DROPIN" <<EOF
# Managed by pg_backup_setup.sh
wal_level = replica
archive_mode = on
archive_command = 'pgbackrest --stanza=${STANZA} archive-push %p'
archive_timeout = 60
EOF
    chown postgres:postgres "$DROPIN"

    local current
    current=$(sudo -u postgres psql -p "$PG_PORT" -Atc "SHOW archive_mode")
    if [[ "$current" == "on" ]]; then
        sudo -u postgres psql -p "$PG_PORT" -Atc "SELECT pg_reload_conf()" >/dev/null
        success "WAL archiving already on; config reloaded."
        return
    fi

    if [[ -z "${ASSUME_YES:-}" ]]; then
        warning "Enabling archive_mode restarts PostgreSQL (a few seconds of downtime)."
        read -rp "Restart postgresql@${PG_VERSION}-main now? [y/N]: " ok
        [[ "$ok" =~ ^[Yy]$ ]] || { error "Aborted. Re-run when a restart is OK."; exit 1; }
    fi
    systemctl restart "postgresql@${PG_VERSION}-main"
    success "PostgreSQL restarted with WAL archiving on."
}

# ------------------------------
# Stanza + first full backup
# ------------------------------
init_repo() {
    log "Creating stanza '${STANZA}' in r2://${R2_BUCKET:-<configured>}..."
    sudo -u postgres pgbackrest --stanza="$STANZA" stanza-create
    log "Checking WAL archiving end to end..."
    sudo -u postgres pgbackrest --stanza="$STANZA" check
    if sudo -u postgres pgbackrest --stanza="$STANZA" info --output=json | grep -q '"backup":\[\]'; then
        log "Taking the first full backup..."
        sudo -u postgres pgbackrest --stanza="$STANZA" --type=full backup
    fi
    success "Repository ready."
}

# ------------------------------
# Schedules (systemd timers, EAT = server local time)
#   full: Sunday 01:30   diff: Mon-Sat 01:30   restore test: 1st of month 03:00
# ------------------------------
install_timers() {
    cat > /usr/local/sbin/pgbackrest-run <<'EOF'
#!/bin/bash
# Usage: pgbackrest-run <full|diff|restore-test>
set -uo pipefail
source /etc/pgbackrest/healthcheck.env 2>/dev/null || true
STANZA="${STANZA:-main}"
[[ "$1" == "restore-test" ]] && HC_URL="${HC_RESTORE_URL:-}"
HC_URL="${HC_URL:-}"
ping() { [[ -n "$HC_URL" ]] && curl -fsS -m 10 --retry 3 -o /dev/null "${HC_URL}${1}" || true; }
ping /start
case "$1" in
    full|diff) pgbackrest --stanza="$STANZA" --type="$1" backup ;;
    restore-test) /usr/local/sbin/pg_restore_test ;;
    *) echo "unknown job: $1" >&2; exit 2 ;;
esac
rc=$?
if [[ $rc -eq 0 ]]; then ping ""; else ping "/fail"; fi
exit $rc
EOF
    chmod 755 /usr/local/sbin/pgbackrest-run

    cat > /etc/systemd/system/pgbackrest@.service <<EOF
[Unit]
Description=pgBackRest %i
After=postgresql@${PG_VERSION}-main.service

[Service]
Type=oneshot
User=postgres
Group=postgres
Environment=STANZA=${STANZA}
ExecStart=/usr/local/sbin/pgbackrest-run %i
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

    timer() {
        cat > "/etc/systemd/system/pgbackrest-$1.timer" <<EOF
[Unit]
Description=pgBackRest $1 schedule

[Timer]
OnCalendar=$2
Persistent=true
RandomizedDelaySec=10m
Unit=pgbackrest@$1.service

[Install]
WantedBy=timers.target
EOF
    }
    timer full         "Sun *-*-* 01:30:00"
    timer diff         "Mon..Sat *-*-* 01:30:00"
    timer restore-test "*-*-01 03:00:00"

    systemctl daemon-reload
    systemctl enable --now pgbackrest-full.timer pgbackrest-diff.timer pgbackrest-restore-test.timer >/dev/null
    success "Timers enabled: $(systemctl list-timers 'pgbackrest-*' --no-legend | wc -l) scheduled."
}

install_restore_test() {
    local src
    src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pg_restore_test.sh"
    [[ -f "$src" ]] || { error "pg_restore_test.sh not found next to this script."; exit 1; }
    install -m 755 "$src" /usr/local/sbin/pg_restore_test
}

detect_cluster
log "Cluster: PostgreSQL ${PG_VERSION}/main on port ${PG_PORT}, data ${PG_DATA}"
read_inputs
install_pgbackrest
write_config

if [[ -n "${RESTORE_MODE:-}" ]]; then
    success "pgBackRest configured for restore only (no archiving, stanza or timers)."
    sudo -u postgres pgbackrest --stanza="$STANZA" info
    echo ""
    log "Next: stop postgres, restore, start it, then re-run this script without RESTORE_MODE:"
    echo "    systemctl stop postgresql@${PG_VERSION}-main"
    echo "    sudo -u postgres pgbackrest --stanza=${STANZA} --delta restore"
    echo "    systemctl start postgresql@${PG_VERSION}-main"
    echo "    bash $0"
    exit 0
fi

configure_archiving
install_restore_test
init_repo
install_timers

echo ""
sudo -u postgres pgbackrest --stanza="$STANZA" info
echo ""
success "============================================================"
success " Backups:      full Sun 01:30, diff Mon-Sat 01:30, WAL continuous"
success " Retention:    4 full backups (~4 weeks) + WAL for point-in-time restore"
success " Restore test: 1st of each month 03:00 (pg_restore_test)"
success " Config:       ${PGBR_CONF}"
success " Logs:         /var/log/pgbackrest, journalctl -u 'pgbackrest@*'"
success "============================================================"
warning "Store ${CIPHER_FILE} off this server. Backups are useless without it."
