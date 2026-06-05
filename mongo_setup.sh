#!/bin/bash

# MongoDB setup: install, harden, create user hierarchy + database
# Pattern: admin user → app user (readWrite) + readonly user (read)
# Run on Ubuntu 22.04+ as root.

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

[[ $EUID -ne 0 ]] && { error "Run as root: sudo bash mongo_setup.sh"; exit 1; }

# ------------------------------
# Inputs
# ------------------------------
read -rp "Application name (lowercase, e.g. myapp): "   APP_NAME
read -rp "Database name [default: \${APP_NAME}_db]: "   DB_NAME_INPUT
read -rp "MongoDB version [default: 8.0]: "             MONGO_VERSION
read -rp "MongoDB port [default: 27017]: "              MONGO_PORT

MONGO_VERSION=${MONGO_VERSION:-8.0}
MONGO_PORT=${MONGO_PORT:-27017}

# Normalize bare major (e.g. "7" → "7.0", "8" → "8.0")
[[ "$MONGO_VERSION" =~ \. ]] || MONGO_VERSION="${MONGO_VERSION}.0"

[[ "$APP_NAME" =~ ^[a-z][a-z0-9_]*$ ]] || {
    error "App name must be lowercase alphanumeric/underscore, starting with a letter."
    exit 1
}

DB_NAME="${DB_NAME_INPUT:-${APP_NAME}_db}"
[[ "$DB_NAME" =~ ^[a-z][a-z0-9_]*$ ]] || {
    error "Database name must be lowercase alphanumeric/underscore, starting with a letter."
    exit 1
}

[[ "$MONGO_PORT" =~ ^[0-9]+$ ]] && (( MONGO_PORT >= 1024 && MONGO_PORT <= 65535 )) || {
    error "Port must be a number between 1024 and 65535."
    exit 1
}

ADMIN_USER="${APP_NAME}_admin"
APP_USER="${APP_NAME}_app"
READONLY_USER="${APP_NAME}_ro"
CREDS_FILE="/root/.mongo_${APP_NAME}.env"

# ------------------------------
# Credential generation
# ------------------------------
gen_password() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32; }

ADMIN_PASSWORD=$(gen_password)
APP_PASSWORD=$(gen_password)
READONLY_PASSWORD=$(gen_password)

# Derive the major version for the repo key (e.g. "8.0" → "8.0")
MONGO_MAJOR="${MONGO_VERSION}"

# ------------------------------
# Install MongoDB from official repo
# ------------------------------
install_mongo() {
    # Validate Ubuntu codename vs MongoDB version compatibility:
    #   Noble  (24.04) → MongoDB 8.0+ only
    #   Jammy  (22.04) → MongoDB 6.0, 7.0, 8.0
    #   Focal  (20.04) → MongoDB 5.0, 6.0
    local UBUNTU_CODENAME
    UBUNTU_CODENAME=$(lsb_release -cs)
    local MAJOR_INT="${MONGO_MAJOR%%.*}"   # "7.0" → "7"

    if [[ "$UBUNTU_CODENAME" == "noble" ]] && (( MAJOR_INT < 8 )); then
        error "MongoDB ${MONGO_MAJOR} has no packages for Ubuntu 24.04 (Noble)."
        error "Use MongoDB 8.0+ on Noble, or downgrade to Ubuntu 22.04 (Jammy)."
        exit 1
    fi
    if [[ "$UBUNTU_CODENAME" == "focal" ]] && (( MAJOR_INT > 6 )); then
        error "MongoDB ${MONGO_MAJOR} has no packages for Ubuntu 20.04 (Focal). Max is 6.0."
        exit 1
    fi

    if command -v mongod &>/dev/null; then
        local installed
        installed=$(mongod --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || true)
        if [[ "$installed" == "$MONGO_MAJOR" ]]; then
            log "MongoDB $MONGO_MAJOR already installed, skipping."
            return
        fi
    fi

    log "Installing MongoDB $MONGO_MAJOR from official repo..."

    # Remove any stale MongoDB repo/keyring files from previous failed runs
    rm -f /etc/apt/sources.list.d/mongodb-org-*.list
    rm -f /usr/share/keyrings/mongodb-server-*.gpg

    apt-get update
    apt-get install -y curl gnupg

    # MongoDB moved key hosting to pgp.mongodb.com (www.mongodb.org/static/pgp returns 404 for recent versions)
    curl -fsSL "https://pgp.mongodb.com/server-${MONGO_MAJOR}.asc" \
        | gpg --dearmor -o /usr/share/keyrings/mongodb-server-${MONGO_MAJOR}.gpg

    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-${MONGO_MAJOR}.gpg ] \
https://repo.mongodb.org/apt/ubuntu ${UBUNTU_CODENAME}/mongodb-org/${MONGO_MAJOR} multiverse" \
        > /etc/apt/sources.list.d/mongodb-org-${MONGO_MAJOR}.list

    apt-get update
    apt-get install -y mongodb-org

    systemctl enable mongod
    systemctl start  mongod

    # Wait for mongod to be ready before continuing
    local attempts=0
    until mongosh --quiet --eval "db.runCommand({ping:1})" &>/dev/null || (( ++attempts >= 15 )); do
        sleep 1
    done
    (( attempts < 15 )) || { error "mongod did not become ready in time."; exit 1; }

    success "MongoDB $MONGO_MAJOR installed"
}

# ------------------------------
# Reset mongod to a known no-auth state on port 27017 so bootstrap
# always has a clean connection regardless of prior partial runs.
# ------------------------------
prepare_for_bootstrap() {
    log "Starting mongod in no-auth mode for bootstrap..."

    cat > /etc/mongod.conf <<'BASECONF'
storage:
  dbPath: /var/lib/mongodb
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log
net:
  port: 27017
  bindIp: 127.0.0.1
BASECONF

    chown root:mongodb /etc/mongod.conf
    chmod 640 /etc/mongod.conf

    systemctl restart mongod

    local attempts=0
    until mongosh --quiet --port 27017 --eval "db.runCommand({ping:1})" &>/dev/null \
          || (( ++attempts >= 20 )); do
        sleep 1
    done
    (( attempts < 20 )) || { error "mongod did not start in no-auth mode."; exit 1; }
}

# ------------------------------
# Create the root admin user (auth is not yet enabled, port 27017)
# ------------------------------
bootstrap_admin() {
    log "Bootstrapping MongoDB admin user..."

    mongosh --quiet --port 27017 admin --eval "
        if (db.getUser('${ADMIN_USER}') === null) {
            db.createUser({
                user: '${ADMIN_USER}',
                pwd:  '${ADMIN_PASSWORD}',
                roles: [
                    { role: 'userAdminAnyDatabase', db: 'admin' },
                    { role: 'dbAdminAnyDatabase',   db: 'admin' },
                    { role: 'readWriteAnyDatabase',  db: 'admin' }
                ]
            });
            print('Admin user created.');
        } else {
            db.updateUser('${ADMIN_USER}', { pwd: '${ADMIN_PASSWORD}' });
            print('Admin user password updated.');
        }
    "

    success "Admin user ready: ${ADMIN_USER}"
}

# ------------------------------
# Harden mongod.conf and enable auth
# ------------------------------
configure_mongo() {
    local CONF="/etc/mongod.conf"

    log "Hardening MongoDB configuration..."

    cat > "$CONF" <<EOF
# mongod.conf — managed by mongo_setup.sh

storage:
  dbPath: /var/lib/mongodb

systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

net:
  port: ${MONGO_PORT}
  bindIp: 127.0.0.1

security:
  authorization: enabled

operationProfiling:
  slowOpThresholdMs: 100
  mode: slowOp
EOF

    chown root:mongodb "$CONF"
    chmod 640 "$CONF"

    systemctl restart mongod

    # Wait for restart
    local attempts=0
    until mongosh --quiet --port "${MONGO_PORT}" \
          -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" --authenticationDatabase admin \
          --eval "db.runCommand({ping:1})" &>/dev/null || (( ++attempts >= 20 )); do
        sleep 1
    done
    if (( attempts >= 20 )); then
        error "mongod did not restart cleanly. Last log lines:"
        tail -20 /var/log/mongodb/mongod.log >&2 || true
        journalctl -u mongod -n 20 --no-pager >&2 || true
        exit 1
    fi

    success "mongod.conf: auth enabled, bound to 127.0.0.1:${MONGO_PORT}, slow-op profiling on."
}

# ------------------------------
# Create app + readonly users on the target database
# ------------------------------
create_users() {
    log "Creating app and readonly users on database '${DB_NAME}'..."

    mongosh --quiet --port "${MONGO_PORT}" \
        -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" --authenticationDatabase admin \
        admin --eval "
        // App user: readWrite on the target database only
        const appDb = db.getSiblingDB('${DB_NAME}');
        if (appDb.getUser('${APP_USER}') === null) {
            appDb.createUser({
                user: '${APP_USER}',
                pwd:  '${APP_PASSWORD}',
                roles: [{ role: 'readWrite', db: '${DB_NAME}' }]
            });
            print('App user created.');
        } else {
            appDb.updateUser('${APP_USER}', { pwd: '${APP_PASSWORD}' });
            print('App user password updated.');
        }

        // Read-only user: read on the target database only
        if (appDb.getUser('${READONLY_USER}') === null) {
            appDb.createUser({
                user: '${READONLY_USER}',
                pwd:  '${READONLY_PASSWORD}',
                roles: [{ role: 'read', db: '${DB_NAME}' }]
            });
            print('Readonly user created.');
        } else {
            appDb.updateUser('${READONLY_USER}', { pwd: '${READONLY_PASSWORD}' });
            print('Readonly user password updated.');
        }
    "

    success "Users created on '${DB_NAME}'."
}

# ------------------------------
# Save credentials to a root-only env file
# ------------------------------
save_credentials() {
    cat > "$CREDS_FILE" <<EOF
# MongoDB credentials — ${APP_NAME}
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# chmod 600 — do not commit this file

MONGO_HOST=127.0.0.1
MONGO_PORT=${MONGO_PORT}
MONGO_DATABASE=${DB_NAME}

# Admin — userAdmin + dbAdmin + readWrite across all databases
MONGO_ADMIN_USER=${ADMIN_USER}
MONGO_ADMIN_PASSWORD=${ADMIN_PASSWORD}
MONGO_ADMIN_URI=mongodb://${ADMIN_USER}:${ADMIN_PASSWORD}@127.0.0.1:${MONGO_PORT}/admin?authSource=admin

# Application — readWrite on ${DB_NAME}
MONGO_APP_USER=${APP_USER}
MONGO_APP_PASSWORD=${APP_PASSWORD}
MONGO_APP_URI=mongodb://${APP_USER}:${APP_PASSWORD}@127.0.0.1:${MONGO_PORT}/${DB_NAME}?authSource=${DB_NAME}

# Read-only — read on ${DB_NAME}
MONGO_READONLY_USER=${READONLY_USER}
MONGO_READONLY_PASSWORD=${READONLY_PASSWORD}
MONGO_READONLY_URI=mongodb://${READONLY_USER}:${READONLY_PASSWORD}@127.0.0.1:${MONGO_PORT}/${DB_NAME}?authSource=${DB_NAME}
EOF
    chmod 600 "$CREDS_FILE"
    success "Credentials saved to $CREDS_FILE (chmod 600)"
}

install_mongo
prepare_for_bootstrap
bootstrap_admin
configure_mongo
create_users
save_credentials

echo ""
success "============================================================"
success " Database:    ${DB_NAME}"
success " Admin:       ${ADMIN_USER}    (userAdmin + dbAdmin + readWrite)"
success " App:         ${APP_USER}     (readWrite on ${DB_NAME})"
success " Read-only:   ${READONLY_USER} (read on ${DB_NAME})"
success " Credentials: ${CREDS_FILE}"
success "============================================================"
warning "Source credentials with: set -a; source ${CREDS_FILE}; set +a"
