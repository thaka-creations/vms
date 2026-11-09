#!/bin/bash

# Restore the latest pgBackRest backup (+ all archived WAL) into a scratch
# directory, start a throwaway PostgreSQL on a private socket, verify it, and
# delete it. Proves the backups in R2 can actually be restored.
#
# Optional: put SQL in /etc/pgbackrest/restore-check.sql (raise an exception
# on failure) and set RESTORE_CHECK_DB in /etc/pgbackrest/healthcheck.env.
#
# Run as root or postgres: sudo bash pg_restore_test.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }

if [[ $EUID -eq 0 ]]; then
    exec runuser -u postgres -- env STANZA="${STANZA:-main}" bash "$(readlink -f "$0")" "$@"
fi
[[ "$(id -un)" == "postgres" ]] || { error "Run as root or postgres."; exit 1; }

source /etc/pgbackrest/healthcheck.env 2>/dev/null || true
STANZA="${STANZA:-main}"
DIR="${RESTORE_DIR:-/var/lib/pgbackrest/restore-test}"
PORT="${RESTORE_PORT:-54329}"
CHECK_SQL="${RESTORE_CHECK_SQL:-/etc/pgbackrest/restore-check.sql}"
CHECK_DB="${RESTORE_CHECK_DB:-postgres}"

PG_VERSION=$(pg_lsclusters --no-header | awk '$2=="main"{print $1}' | sort -nr | head -1)
BIN="/usr/lib/postgresql/${PG_VERSION}/bin"
[[ -x "$BIN/pg_ctl" ]] || { error "PostgreSQL ${PG_VERSION} binaries not found in $BIN."; exit 1; }

cleanup() {
    "$BIN/pg_ctl" -D "$DIR" status >/dev/null 2>&1 && "$BIN/pg_ctl" -D "$DIR" -m immediate stop >/dev/null 2>&1
    rm -rf "$DIR"
}
trap cleanup EXIT

cleanup
install -d -m 700 "$DIR"

log "Restoring latest backup of '${STANZA}' into $DIR..."
started=$(date +%s)
pgbackrest --stanza="$STANZA" --pg1-path="$DIR" --archive-mode=off restore

cat > "$DIR/postgresql.conf" <<EOF
port = ${PORT}
listen_addresses = ''
unix_socket_directories = '${DIR}'
hot_standby = off
archive_mode = off
ssl = off
shared_buffers = 128MB
max_wal_size = 4GB
EOF
echo "local all all peer" > "$DIR/pg_hba.conf"
: > "$DIR/pg_ident.conf"

log "Replaying WAL to the end of the archive..."
"$BIN/pg_ctl" -D "$DIR" -l "$DIR/restore.log" -w -t 7200 start >/dev/null || {
    error "Restored cluster failed to start:"; tail -30 "$DIR/restore.log" >&2; exit 1;
}

q() { psql -h "$DIR" -p "$PORT" -X -v ON_ERROR_STOP=1 -At "$@"; }

deadline=$(( $(date +%s) + ${RESTORE_TIMEOUT:-7200} ))
until [[ "$(q -d postgres -c 'SELECT pg_is_in_recovery()' 2>/dev/null)" == "f" ]]; do
    "$BIN/pg_ctl" -D "$DIR" status >/dev/null 2>&1 || {
        error "Restored cluster stopped during recovery:"; tail -30 "$DIR/restore.log" >&2; exit 1;
    }
    (( $(date +%s) < deadline )) || {
        error "Recovery did not finish within ${RESTORE_TIMEOUT:-7200}s:"; tail -30 "$DIR/restore.log" >&2; exit 1;
    }
    sleep 2
done

log "Databases in the restored copy:"
q -d postgres -F $'\t' -c "SELECT datname, pg_size_pretty(pg_database_size(datname))
                           FROM pg_database WHERE NOT datistemplate ORDER BY 1" | sed 's/^/    /'

recovered_to=$(grep -oE "last completed transaction was at log time [^ ]+ [^ ]+" "$DIR/restore.log" | tail -1 | sed 's/.*log time //')
log "Recovered up to: ${recovered_to:-end of archive}"

if [[ -f "$CHECK_SQL" ]]; then
    log "Running $CHECK_SQL against ${CHECK_DB}..."
    q -d "$CHECK_DB" -f "$CHECK_SQL" >/dev/null
    success "Data checks passed."
fi

success "Restore test passed in $(( $(date +%s) - started ))s."
