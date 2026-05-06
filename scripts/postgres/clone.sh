#!/usr/bin/env bash
# Clone a PostgreSQL database using `CREATE DATABASE … TEMPLATE …`.
#
# Designed to run inside the official `postgres:N` Docker image — no extra
# tools required beyond `psql`. The script connects to a maintenance database
# (defaults to `postgres`) and issues the clone. Existing connections to the
# source database are terminated first so the TEMPLATE clause succeeds.
#
# Required environment variables:
#   PGHOST              database server hostname
#   PGUSER              role with CREATEDB and connect privileges on the
#                       maintenance database
#   PGPASSWORD          password for that role
#   SOURCE_DATABASE     existing database to clone from (e.g. myapp_staging)
#   TARGET_DATABASE     new database to create (must not yet exist)
#
# Optional environment variables:
#   PGPORT              default 5432
#   PGSSLMODE           e.g. require, prefer, disable
#   MAINTENANCE_DATABASE  default 'postgres'
#   DISCONNECT_TIMEOUT  seconds to wait for active sessions on the source DB
#                       to drain before issuing CREATE DATABASE (default 15).
#
# Exits 0 on success or when the target database already exists (idempotent).
# Exits non-zero on any other failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/identifier-safe.sh
source "${SCRIPT_DIR}/../lib/identifier-safe.sh"

: "${PGHOST:?PGHOST is required}"
: "${PGUSER:?PGUSER is required}"
: "${PGPASSWORD:?PGPASSWORD is required}"
: "${SOURCE_DATABASE:?SOURCE_DATABASE is required}"
: "${TARGET_DATABASE:?TARGET_DATABASE is required}"

PGPORT="${PGPORT:-5432}"
MAINTENANCE_DATABASE="${MAINTENANCE_DATABASE:-postgres}"
DISCONNECT_TIMEOUT="${DISCONNECT_TIMEOUT:-15}"

kp_assert_identifier "$SOURCE_DATABASE" "SOURCE_DATABASE"
kp_assert_identifier "$TARGET_DATABASE" "TARGET_DATABASE"
kp_assert_identifier "$MAINTENANCE_DATABASE" "MAINTENANCE_DATABASE"

export PGHOST PGPORT PGUSER PGPASSWORD
[ -n "${PGSSLMODE:-}" ] && export PGSSLMODE
export PGDATABASE="$MAINTENANCE_DATABASE"

psql_scalar() {
  # -t: tuples only, -A: unaligned, -q: quiet — yields a single trimmed value.
  psql -v ON_ERROR_STOP=1 -tAq "$@"
}

# Idempotency: succeed if target already exists.
if [ -n "$(psql_scalar -c "SELECT 1 FROM pg_database WHERE datname = '${TARGET_DATABASE}' LIMIT 1" || true)" ]; then
  kp_log "Target database '${TARGET_DATABASE}' already exists — nothing to do."
  exit 0
fi

# Source must exist or we'd produce a confusing error from CREATE DATABASE.
if [ -z "$(psql_scalar -c "SELECT 1 FROM pg_database WHERE datname = '${SOURCE_DATABASE}' LIMIT 1" || true)" ]; then
  kp_die "Source database '${SOURCE_DATABASE}' does not exist on ${PGHOST}:${PGPORT}."
fi

kp_log "Terminating other connections to '${SOURCE_DATABASE}'…"
psql -v ON_ERROR_STOP=1 -q -c "
  SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE datname = '${SOURCE_DATABASE}' AND pid <> pg_backend_pid();
" >/dev/null || kp_log "(termination call returned non-zero, continuing)"

deadline=$(( $(date +%s) + DISCONNECT_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  remaining="$(psql_scalar -c "SELECT count(*) FROM pg_stat_activity WHERE datname = '${SOURCE_DATABASE}' AND pid <> pg_backend_pid()")"
  if [ "${remaining:-0}" = "0" ]; then break; fi
  sleep 0.5
done
remaining="$(psql_scalar -c "SELECT count(*) FROM pg_stat_activity WHERE datname = '${SOURCE_DATABASE}' AND pid <> pg_backend_pid()")"
if [ "${remaining:-0}" != "0" ]; then
  kp_log "WARNING: ${remaining} session(s) still attached to '${SOURCE_DATABASE}'. CREATE DATABASE may fail."
fi

kp_log "Cloning '${SOURCE_DATABASE}' -> '${TARGET_DATABASE}'…"
# Identifiers are validated above, so they are safe to interpolate. We still
# wrap in double-quotes so PostgreSQL parses them as case-sensitive idents.
psql -v ON_ERROR_STOP=1 -q -c "CREATE DATABASE \"${TARGET_DATABASE}\" TEMPLATE \"${SOURCE_DATABASE}\";"
kp_log "Clone complete."
