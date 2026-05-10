#!/bin/bash

# PostgreSQL setup: install, harden, create role hierarchy + database
# Pattern: group role (NOLOGIN) → admin, app, and readonly login roles
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

[[ $EUID -ne 0 ]] && { error "Run as root: sudo bash pg_setup.sh"; exit 1; }

# ------------------------------
# Inputs
# ------------------------------
read -rp "Application name (lowercase, e.g. myapp): "  APP_NAME
read -rp "Database name [default: \${APP_NAME}_db]: "  DB_NAME_INPUT
read -rp "PostgreSQL version [default: 16]: "           PG_VERSION
read -rp "PostgreSQL port [default: 5433]: "            PG_PORT
PG_VERSION=${PG_VERSION:-16}
PG_PORT=${PG_PORT:-5433}

[[ "$APP_NAME" =~ ^[a-z][a-z0-9_]*$ ]] || {
    error "App name must be lowercase alphanumeric/underscore, starting with a letter."
    exit 1
}

DB_NAME="${DB_NAME_INPUT:-${APP_NAME}_db}"
[[ "$DB_NAME" =~ ^[a-z][a-z0-9_]*$ ]] || {
    error "Database name must be lowercase alphanumeric/underscore, starting with a letter."
    exit 1
}

[[ "$PG_PORT" =~ ^[0-9]+$ ]] && (( PG_PORT >= 1024 && PG_PORT <= 65535 )) || {
    error "Port must be a number between 1024 and 65535."
    exit 1
}
GROUP_ROLE="${APP_NAME}"                  # NOLOGIN owner — never connects directly
ADMIN_ROLE="${APP_NAME}_admin"            # LOGIN — runs migrations, owns schema objects
APP_ROLE="${APP_NAME}_app"               # LOGIN — DML (SELECT/INSERT/UPDATE/DELETE)
READONLY_ROLE="${APP_NAME}_ro"            # LOGIN — SELECT only (analytics, reporting)
CREDS_FILE="/root/.pg_${APP_NAME}.env"

# ------------------------------
# Credential generation
# Never hardcode passwords — generate cryptographically random ones.
# ------------------------------
gen_password() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32; }

ADMIN_PASSWORD=$(gen_password)
APP_PASSWORD=$(gen_password)
READONLY_PASSWORD=$(gen_password)

# ------------------------------
# Install PostgreSQL from PGDG (official repo, not Ubuntu's lagged packages)
# ------------------------------
install_postgres() {
    if pg_lsclusters 2>/dev/null | grep -q "^$PG_VERSION"; then
        log "PostgreSQL $PG_VERSION cluster already exists, skipping install."
        return
    fi

    log "Installing PostgreSQL $PG_VERSION from PGDG..."
    apt-get update
    apt-get install -y curl ca-certificates
    install -d /usr/share/postgresql-common/pgdg
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
    sh -c "echo 'deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
        https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main' \
        > /etc/apt/sources.list.d/pgdg.list"
    apt-get update
    apt-get install -y "postgresql-$PG_VERSION"
    systemctl enable "postgresql@${PG_VERSION}-main"
    systemctl start  "postgresql@${PG_VERSION}-main"
    success "PostgreSQL $PG_VERSION installed"
}

# ------------------------------
# Harden postgresql.conf and pg_hba.conf
# ------------------------------
configure_postgres() {
    local CONF_DIR="/etc/postgresql/$PG_VERSION/main"
    local PG_CONF="$CONF_DIR/postgresql.conf"
    local PG_HBA="$CONF_DIR/pg_hba.conf"

    log "Hardening PostgreSQL configuration..."

    # Append hardening block — idempotent guard prevents duplicate appends.
    if ! grep -q "# ── hardening-block" "$PG_CONF"; then
        cat >> "$PG_CONF" <<EOF

# ── hardening-block (managed by pg_setup.sh) ──────────────────────────────────
listen_addresses          = 'localhost'   # never expose on 0.0.0.0 unless explicitly needed
port                      = ${PG_PORT}
ssl                       = on
password_encryption       = scram-sha-256 # stronger than md5; required for pg_hba scram entries

max_connections           = 100

# Audit logging — who connected, when, and how long queries took
log_connections           = on
log_disconnections        = on
log_duration              = off           # too noisy; enable per-session when debugging
log_line_prefix           = '%t [%p]: user=%u,db=%d,app=%a,client=%h '
log_statement             = 'ddl'         # always log schema changes
log_min_duration_statement= 2000          # log queries slower than 2s
log_lock_waits            = on
EOF
    fi

    # pg_hba.conf — scram-sha-256 everywhere except the postgres unix socket
    # which uses peer (needed for pg_dump, pg_restore run by the postgres OS user)
    cat > "$PG_HBA" <<EOF
# TYPE  DATABASE        USER            ADDRESS           METHOD
# postgres OS user — trusted locally for admin tasks
local   all             postgres                          peer
# All other local connections — scram-sha-256
local   all             all                               scram-sha-256
host    all             all             127.0.0.1/32      scram-sha-256
host    all             all             ::1/128           scram-sha-256
EOF

    # SSL — generate a self-signed cert if one doesn't already exist.
    local SSL_DIR="$CONF_DIR"
    if [[ ! -f "$SSL_DIR/server.crt" || ! -f "$SSL_DIR/server.key" ]]; then
        log "Generating self-signed SSL certificate (replace with a CA-signed cert in production)..."
        openssl req -new -x509 -days 3650 -nodes \
            -subj "/CN=postgresql-${APP_NAME}" \
            -keyout "$SSL_DIR/server.key" \
            -out    "$SSL_DIR/server.crt" 2>/dev/null
        chown postgres:postgres "$SSL_DIR/server.key" "$SSL_DIR/server.crt"
        chmod 600 "$SSL_DIR/server.key"
        chmod 644 "$SSL_DIR/server.crt"
    fi

    # port is a startup parameter — requires a full restart, not just reload.
    systemctl restart "postgresql@${PG_VERSION}-main"
    success "pg_hba.conf: scram-sha-256 enforced. postgresql.conf: DDL logging + slow query logging on."
}

# ------------------------------
# Role hierarchy + database
# ------------------------------
create_roles_and_db() {
    log "Creating role hierarchy and database..."

    sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
-- ── Group role ──────────────────────────────────────────────────────────────
-- NOLOGIN, NOINHERIT: a pure permission container, never used to connect.
-- Every schema object is owned by this role so privilege grants are uniform.
DO \$\$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${GROUP_ROLE}') THEN
        CREATE ROLE ${GROUP_ROLE} NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE;
    END IF;
END \$\$;

-- ── Admin role ───────────────────────────────────────────────────────────────
-- Runs migrations and DDL. Inherits group role so it can act as the owner.
-- connection_limit keeps a runaway migration tool from exhausting the pool.
DO \$\$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${ADMIN_ROLE}') THEN
        CREATE ROLE ${ADMIN_ROLE} LOGIN INHERIT PASSWORD '${ADMIN_PASSWORD}'
            CONNECTION LIMIT 5
            IN ROLE ${GROUP_ROLE};
    ELSE
        ALTER ROLE ${ADMIN_ROLE} PASSWORD '${ADMIN_PASSWORD}';
    END IF;
END \$\$;

-- ── App role ─────────────────────────────────────────────────────────────────
-- DML only. NOINHERIT so it can't silently acquire group-role DDL permissions.
DO \$\$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${APP_ROLE}') THEN
        CREATE ROLE ${APP_ROLE} LOGIN NOINHERIT PASSWORD '${APP_PASSWORD}'
            CONNECTION LIMIT 50;
    ELSE
        ALTER ROLE ${APP_ROLE} PASSWORD '${APP_PASSWORD}';
    END IF;
END \$\$;

-- ── Read-only role ───────────────────────────────────────────────────────────
-- SELECT only — safe to give to analytics tools, read replicas, reporting.
DO \$\$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${READONLY_ROLE}') THEN
        CREATE ROLE ${READONLY_ROLE} LOGIN NOINHERIT PASSWORD '${READONLY_PASSWORD}'
            CONNECTION LIMIT 20;
    ELSE
        ALTER ROLE ${READONLY_ROLE} PASSWORD '${READONLY_PASSWORD}';
    END IF;
END \$\$;

-- ── Database ─────────────────────────────────────────────────────────────────
SELECT 'CREATE DATABASE ${DB_NAME} OWNER ${GROUP_ROLE}
    ENCODING ''UTF8''
    LC_COLLATE ''en_US.UTF-8''
    LC_CTYPE ''en_US.UTF-8''
    TEMPLATE template0'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}') \gexec

SQL

    # Connect to the new database to configure schema permissions
    sudo -u postgres psql -v ON_ERROR_STOP=1 -d "${DB_NAME}" <<SQL
-- ── Database-level connection control ────────────────────────────────────────
-- PostgreSQL grants CONNECT to PUBLIC by default — any role on the instance
-- can connect. Remove that and grant explicitly to only our roles.
REVOKE CONNECT ON DATABASE ${DB_NAME} FROM PUBLIC;
GRANT  CONNECT ON DATABASE ${DB_NAME} TO ${ADMIN_ROLE}, ${APP_ROLE}, ${READONLY_ROLE};

-- ── Lock down the public schema ──────────────────────────────────────────────
-- By default every role can create objects in public. Remove that.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL    ON SCHEMA public FROM PUBLIC;
GRANT  USAGE  ON SCHEMA public TO ${GROUP_ROLE};

-- ── App role: DML on current and future tables ───────────────────────────────
GRANT USAGE ON SCHEMA public TO ${APP_ROLE};
GRANT SELECT, INSERT, UPDATE, DELETE
    ON ALL TABLES IN SCHEMA public TO ${APP_ROLE};
GRANT USAGE, SELECT
    ON ALL SEQUENCES IN SCHEMA public TO ${APP_ROLE};

-- DEFAULT PRIVILEGES: objects created BY ${ADMIN_ROLE} are automatically
-- accessible to app and readonly roles. Without FOR ROLE, only objects created
-- by the CURRENT SESSION user get these defaults — useless for future deploys.
ALTER DEFAULT PRIVILEGES FOR ROLE ${ADMIN_ROLE} IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES    TO ${APP_ROLE};
ALTER DEFAULT PRIVILEGES FOR ROLE ${ADMIN_ROLE} IN SCHEMA public
    GRANT USAGE, SELECT                  ON SEQUENCES  TO ${APP_ROLE};

-- ── Read-only role: SELECT on current and future tables ──────────────────────
GRANT USAGE  ON SCHEMA public TO ${READONLY_ROLE};
GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${READONLY_ROLE};
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO ${READONLY_ROLE};

ALTER DEFAULT PRIVILEGES FOR ROLE ${ADMIN_ROLE} IN SCHEMA public
    GRANT SELECT ON TABLES    TO ${READONLY_ROLE};
ALTER DEFAULT PRIVILEGES FOR ROLE ${ADMIN_ROLE} IN SCHEMA public
    GRANT SELECT ON SEQUENCES TO ${READONLY_ROLE};

-- ── Admin role: full DDL on the database ─────────────────────────────────────
GRANT ALL ON SCHEMA public TO ${ADMIN_ROLE};

SQL

    success "Roles created and privileges set."
}

# ------------------------------
# Save credentials to a root-only env file
# ------------------------------
save_credentials() {
    cat > "$CREDS_FILE" <<EOF
# PostgreSQL credentials — ${APP_NAME}
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# chmod 600 — do not commit this file

PG_HOST=localhost
PG_PORT=${PG_PORT}
PG_DATABASE=${DB_NAME}

# Admin — DDL, migrations
PG_ADMIN_USER=${ADMIN_ROLE}
PG_ADMIN_PASSWORD=${ADMIN_PASSWORD}
PG_ADMIN_URL=postgresql://${ADMIN_ROLE}:${ADMIN_PASSWORD}@localhost:${PG_PORT}/${DB_NAME}

# Application — DML only
PG_APP_USER=${APP_ROLE}
PG_APP_PASSWORD=${APP_PASSWORD}
PG_APP_URL=postgresql://${APP_ROLE}:${APP_PASSWORD}@localhost:${PG_PORT}/${DB_NAME}

# Read-only — SELECT only
PG_READONLY_USER=${READONLY_ROLE}
PG_READONLY_PASSWORD=${READONLY_PASSWORD}
PG_READONLY_URL=postgresql://${READONLY_ROLE}:${READONLY_PASSWORD}@localhost:${PG_PORT}/${DB_NAME}
EOF
    chmod 600 "$CREDS_FILE"
    success "Credentials saved to $CREDS_FILE (chmod 600)"
}

install_postgres
configure_postgres
create_roles_and_db
save_credentials

echo ""
success "============================================================"
success " Database:    ${DB_NAME}"
success " Group role:  ${GROUP_ROLE}   (NOLOGIN — owns all objects)"
success " Admin:       ${ADMIN_ROLE}    (DDL + migrations)"
success " App:         ${APP_ROLE}     (DML only)"
success " Read-only:   ${READONLY_ROLE} (SELECT only)"
success " Credentials: ${CREDS_FILE}"
success "============================================================"
warning "Source credentials with: set -a; source ${CREDS_FILE}; set +a"
