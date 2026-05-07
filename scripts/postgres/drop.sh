#!/usr/bin/env bash
# Drop a PostgreSQL database (used during PR teardown).
#
# Required environment variables:
#   PGHOST, PGUSER, PGPASSWORD, TARGET_DATABASE
#
# Optional environment variables:
#   PGPORT (default 5432), PGSSLMODE, MAINTENANCE_DATABASE (default 'postgres')
#
# Idempotent: exits 0 whether the database existed or not.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/identifier-safe.sh
source "${SCRIPT_DIR}/../lib/identifier-safe.sh"

: "${PGHOST:?PGHOST is required}"
: "${PGUSER:?PGUSER is required}"
: "${PGPASSWORD:?PGPASSWORD is required}"
: "${TARGET_DATABASE:?TARGET_DATABASE is required}"

PGPORT="${PGPORT:-5432}"
MAINTENANCE_DATABASE="${MAINTENANCE_DATABASE:-postgres}"

kp_assert_identifier "$TARGET_DATABASE" "TARGET_DATABASE"
kp_assert_identifier "$MAINTENANCE_DATABASE" "MAINTENANCE_DATABASE"

export PGHOST PGPORT PGUSER PGPASSWORD
[ -n "${PGSSLMODE:-}" ] && export PGSSLMODE
export PGDATABASE="$MAINTENANCE_DATABASE"

psql_scalar() { psql -v ON_ERROR_STOP=1 -tAq "$@"; }

# Distinguish "database does not exist" (a clean no-op) from "couldn't
# even connect" (a real failure we should surface). Previously we used
# `… || true` and treated any empty output as "doesn't exist", which
# silently masked connection-limit / auth errors and let teardown report
# success while leaving the per-PR DB orphaned.
if ! exists_out="$(psql_scalar -c "SELECT 1 FROM pg_database WHERE datname = '${TARGET_DATABASE}' LIMIT 1" 2>&1)"; then
  kp_die "Could not query maintenance DB '${MAINTENANCE_DATABASE}' on ${PGHOST}:${PGPORT}: ${exists_out}"
fi
if [ -z "$exists_out" ]; then
  kp_log "Database '${TARGET_DATABASE}' does not exist — nothing to drop."
  exit 0
fi

kp_log "Terminating connections to '${TARGET_DATABASE}'…"
psql -v ON_ERROR_STOP=1 -q -c "
  SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE datname = '${TARGET_DATABASE}' AND pid <> pg_backend_pid();
" >/dev/null || kp_log "(termination call returned non-zero, continuing)"

kp_log "Dropping '${TARGET_DATABASE}'…"
psql -v ON_ERROR_STOP=1 -q -c "DROP DATABASE IF EXISTS \"${TARGET_DATABASE}\" WITH (FORCE);"
kp_log "Drop complete."
