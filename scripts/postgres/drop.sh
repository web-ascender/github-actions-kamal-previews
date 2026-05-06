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

fd_assert_identifier "$TARGET_DATABASE" "TARGET_DATABASE"
fd_assert_identifier "$MAINTENANCE_DATABASE" "MAINTENANCE_DATABASE"

export PGHOST PGPORT PGUSER PGPASSWORD
[ -n "${PGSSLMODE:-}" ] && export PGSSLMODE
export PGDATABASE="$MAINTENANCE_DATABASE"

psql_scalar() { psql -v ON_ERROR_STOP=1 -tAq "$@"; }

if [ -z "$(psql_scalar -c "SELECT 1 FROM pg_database WHERE datname = '${TARGET_DATABASE}' LIMIT 1" || true)" ]; then
  fd_log "Database '${TARGET_DATABASE}' does not exist — nothing to drop."
  exit 0
fi

fd_log "Terminating connections to '${TARGET_DATABASE}'…"
psql -v ON_ERROR_STOP=1 -q -c "
  SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE datname = '${TARGET_DATABASE}' AND pid <> pg_backend_pid();
" >/dev/null || fd_log "(termination call returned non-zero, continuing)"

fd_log "Dropping '${TARGET_DATABASE}'…"
psql -v ON_ERROR_STOP=1 -q -c "DROP DATABASE IF EXISTS \"${TARGET_DATABASE}\" WITH (FORCE);"
fd_log "Drop complete."
