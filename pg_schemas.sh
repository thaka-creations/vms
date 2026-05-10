#!/bin/bash

# PostgreSQL multi-schema setup with isolated role hierarchies.
#
# For each schema this script creates:
#   <schema>_owner  — NOLOGIN, owns all objects in the schema
#   <schema>_rw     — NOLOGIN, DML (SELECT/INSERT/UPDATE/DELETE)
#   <schema>_ro     — NOLOGIN, SELECT only
#   <schema>_user   — LOGIN,   inherits <schema>_rw (application user)
#   <schema>_reader — LOGIN,   inherits <schema>_ro (analytics / reporting)
#
# Why group roles + login roles instead of direct grants?
# Because you can GRANT the group role to any new user later without re-running
# all the individual GRANT statements. One GRANT IN ROLE, done.
#
# Run after pg_setup.sh. Requires root.

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

[[ $EUID -ne 0 ]] && { error "Run as root: sudo bash pg_schemas.sh"; exit 1; }

# ------------------------------
# Inputs
# ------------------------------
read -rp "Target database name: "                      DB_NAME
read -rp "PostgreSQL port [default: 5433]: "           PG_PORT
read -rp "Space-separated schema names (e.g. sales inventory finance): " SCHEMAS_INPUT
read -rp "Admin role that will run migrations [default: ${DB_NAME%_*}_admin]: " MIGRATION_ROLE
PG_PORT=${PG_PORT:-5433}
MIGRATION_ROLE=${MIGRATION_ROLE:-"${DB_NAME%_*}_admin"}

[[ "$PG_PORT" =~ ^[0-9]+$ ]] && (( PG_PORT >= 1024 && PG_PORT <= 65535 )) || {
    error "Port must be a number between 1024 and 65535."
    exit 1
}

CREDS_FILE="/root/.pg_schemas_${DB_NAME}.env"

# Validate
[[ "$DB_NAME" =~ ^[a-z][a-z0-9_]*$ ]] || {
    error "Database name must be lowercase alphanumeric/underscore."
    exit 1
}

# Convert input to array
read -ra SCHEMAS <<< "$SCHEMAS_INPUT"
[[ ${#SCHEMAS[@]} -eq 0 ]] && { error "Provide at least one schema name."; exit 1; }

for s in "${SCHEMAS[@]}"; do
    [[ "$s" =~ ^[a-z][a-z0-9_]*$ ]] || {
        error "Schema name '$s' must be lowercase alphanumeric/underscore."
        exit 1
    }
done

# Verify database exists
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" \
    | grep -q 1 || {
    error "Database '${DB_NAME}' does not exist. Run pg_setup.sh first."
    exit 1
}

gen_password() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32; }

# ------------------------------
# Process each schema
# ------------------------------
declare -A USER_PASSWORDS
declare -A READER_PASSWORDS

setup_schema() {
    local SCHEMA="$1"

    local OWNER_ROLE="${SCHEMA}_owner"   # NOLOGIN — owns schema objects
    local RW_ROLE="${SCHEMA}_rw"         # NOLOGIN — DML group role
    local RO_ROLE="${SCHEMA}_ro"         # NOLOGIN — SELECT group role
    local APP_USER="${SCHEMA}_user"      # LOGIN — inherits rw
    local RO_USER="${SCHEMA}_reader"     # LOGIN — inherits ro

    local APP_PASSWORD
    local RO_PASSWORD
    APP_PASSWORD=$(gen_password)
    RO_PASSWORD=$(gen_password)
    USER_PASSWORDS["$SCHEMA"]="$APP_PASSWORD"
    READER_PASSWORDS["$SCHEMA"]="$RO_PASSWORD"

    log "Setting up schema: ${SCHEMA}..."

    sudo -u postgres psql -v ON_ERROR_STOP=1 -d "${DB_NAME}" <<SQL
-- ── Grant schema login users connect access ───────────────────────────────────
-- pg_setup.sh revokes CONNECT from PUBLIC — grant it explicitly here.
GRANT CONNECT ON DATABASE ${DB_NAME} TO ${APP_USER}, ${RO_USER};

-- ── Group roles (NOLOGIN) ────────────────────────────────────────────────────
DO \$\$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${OWNER_ROLE}') THEN
        CREATE ROLE ${OWNER_ROLE} NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE;
    END IF;
END \$\$;

DO \$\$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${RW_ROLE}') THEN
        CREATE ROLE ${RW_ROLE} NOLOGIN NOINHERIT;
    END IF;
END \$\$;

DO \$\$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${RO_ROLE}') THEN
        CREATE ROLE ${RO_ROLE} NOLOGIN NOINHERIT;
    END IF;
END \$\$;

-- ── Login roles ───────────────────────────────────────────────────────────────
DO \$\$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${APP_USER}') THEN
        CREATE ROLE ${APP_USER} LOGIN INHERIT PASSWORD '${APP_PASSWORD}'
            CONNECTION LIMIT 30
            IN ROLE ${RW_ROLE};
    ELSE
        ALTER ROLE ${APP_USER} PASSWORD '${APP_PASSWORD}';
    END IF;
END \$\$;

DO \$\$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${RO_USER}') THEN
        CREATE ROLE ${RO_USER} LOGIN INHERIT PASSWORD '${RO_PASSWORD}'
            CONNECTION LIMIT 10
            IN ROLE ${RO_ROLE};
    ELSE
        ALTER ROLE ${RO_USER} PASSWORD '${RO_PASSWORD}';
    END IF;
END \$\$;

-- ── Schema ────────────────────────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS ${SCHEMA} AUTHORIZATION ${OWNER_ROLE};

-- Lock it down — only explicit grants get in.
REVOKE ALL ON SCHEMA ${SCHEMA} FROM PUBLIC;

-- ── Privilege grants ──────────────────────────────────────────────────────────
-- USAGE lets a role resolve names inside the schema. Without it, even a SELECT
-- grant on a specific table is useless — the role can't navigate to the table.
GRANT USAGE ON SCHEMA ${SCHEMA} TO ${RW_ROLE}, ${RO_ROLE};

-- Existing objects
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA ${SCHEMA} TO ${RW_ROLE};
GRANT USAGE, SELECT                  ON ALL SEQUENCES IN SCHEMA ${SCHEMA} TO ${RW_ROLE};
GRANT SELECT                         ON ALL TABLES    IN SCHEMA ${SCHEMA} TO ${RO_ROLE};
GRANT SELECT                         ON ALL SEQUENCES IN SCHEMA ${SCHEMA} TO ${RO_ROLE};

-- Future objects created BY the migration role.
-- This is the piece most developers get wrong: ALTER DEFAULT PRIVILEGES without
-- FOR ROLE only applies to objects created by whoever runs this script. Since
-- migrations run as ${MIGRATION_ROLE}, we need to specify that explicitly.
ALTER DEFAULT PRIVILEGES FOR ROLE ${MIGRATION_ROLE} IN SCHEMA ${SCHEMA}
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES    TO ${RW_ROLE};
ALTER DEFAULT PRIVILEGES FOR ROLE ${MIGRATION_ROLE} IN SCHEMA ${SCHEMA}
    GRANT USAGE, SELECT                  ON SEQUENCES  TO ${RW_ROLE};
ALTER DEFAULT PRIVILEGES FOR ROLE ${MIGRATION_ROLE} IN SCHEMA ${SCHEMA}
    GRANT EXECUTE                        ON FUNCTIONS  TO ${RW_ROLE};
ALTER DEFAULT PRIVILEGES FOR ROLE ${MIGRATION_ROLE} IN SCHEMA ${SCHEMA}
    GRANT SELECT                         ON TABLES     TO ${RO_ROLE};
ALTER DEFAULT PRIVILEGES FOR ROLE ${MIGRATION_ROLE} IN SCHEMA ${SCHEMA}
    GRANT SELECT                         ON SEQUENCES  TO ${RO_ROLE};
ALTER DEFAULT PRIVILEGES FOR ROLE ${MIGRATION_ROLE} IN SCHEMA ${SCHEMA}
    GRANT EXECUTE                        ON FUNCTIONS  TO ${RO_ROLE};

-- Future objects created BY the owner role (e.g. if seeds run as owner)
ALTER DEFAULT PRIVILEGES FOR ROLE ${OWNER_ROLE} IN SCHEMA ${SCHEMA}
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES    TO ${RW_ROLE};
ALTER DEFAULT PRIVILEGES FOR ROLE ${OWNER_ROLE} IN SCHEMA ${SCHEMA}
    GRANT USAGE, SELECT                  ON SEQUENCES  TO ${RW_ROLE};
ALTER DEFAULT PRIVILEGES FOR ROLE ${OWNER_ROLE} IN SCHEMA ${SCHEMA}
    GRANT SELECT                         ON TABLES     TO ${RO_ROLE};

-- ── search_path ───────────────────────────────────────────────────────────────
-- Pin each login role to its schema so unqualified table names resolve correctly
-- without requiring the app to set search_path at connection time.
ALTER ROLE ${APP_USER} SET search_path TO ${SCHEMA}, public;
ALTER ROLE ${RO_USER}  SET search_path TO ${SCHEMA}, public;

SQL

    success "Schema '${SCHEMA}' ready — roles: ${APP_USER} (rw), ${RO_USER} (ro)"
}

# ------------------------------
# Run
# ------------------------------
for SCHEMA in "${SCHEMAS[@]}"; do
    setup_schema "$SCHEMA"
done

# ------------------------------
# Save credentials
# ------------------------------
{
    echo "# Schema credentials — ${DB_NAME}"
    echo "# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "# chmod 600 — do not commit"
    echo ""

    for SCHEMA in "${SCHEMAS[@]}"; do
        echo "# ── ${SCHEMA} ──────────────────────────────────────────────────"
        echo "${SCHEMA^^}_RW_USER=${SCHEMA}_user"
        echo "${SCHEMA^^}_RW_PASSWORD=${USER_PASSWORDS[$SCHEMA]}"
        echo "${SCHEMA^^}_RW_URL=postgresql://${SCHEMA}_user:${USER_PASSWORDS[$SCHEMA]}@localhost:${PG_PORT}/${DB_NAME}?options=-csearch_path%3D${SCHEMA}"
        echo "${SCHEMA^^}_RO_USER=${SCHEMA}_reader"
        echo "${SCHEMA^^}_RO_PASSWORD=${READER_PASSWORDS[$SCHEMA]}"
        echo "${SCHEMA^^}_RO_URL=postgresql://${SCHEMA}_reader:${READER_PASSWORDS[$SCHEMA]}@localhost:${PG_PORT}/${DB_NAME}?options=-csearch_path%3D${SCHEMA}"
        echo ""
    done
} > "$CREDS_FILE"
chmod 600 "$CREDS_FILE"

# ------------------------------
# Summary
# ------------------------------
echo ""
success "======================================================================"
success " Database: ${DB_NAME}"
success " Schemas:  ${SCHEMAS[*]}"
success "======================================================================"
for SCHEMA in "${SCHEMAS[@]}"; do
    echo -e "  ${BLUE}${SCHEMA}${NC}"
    echo -e "    rw  → ${SCHEMA}_user    (SELECT/INSERT/UPDATE/DELETE)"
    echo -e "    ro  → ${SCHEMA}_reader  (SELECT only)"
done
echo ""
success " Credentials: ${CREDS_FILE}"
success "======================================================================"
warning " To grant a new team member access to a schema's data:"
warning "   GRANT <schema>_rw TO new_login_role;  -- read-write"
warning "   GRANT <schema>_ro TO new_login_role;  -- read-only"
