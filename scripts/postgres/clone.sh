#!/usr/bin/env bash
# Clone a PostgreSQL database by streaming pg_dump | psql.
#
# Designed to run inside the official `postgres:N` Docker image. We avoid the
# faster `CREATE DATABASE … TEMPLATE` form because it requires zero active
# connections to the source — a hard requirement to meet for Solid Queue /
# Solid Cache / Solid Cable databases whose workers reconnect immediately
# after termination, and one that managed services (DigitalOcean, RDS) often
# don't grant enough privilege to enforce. `pg_dump | psql` works under any
# concurrent load and on every managed Postgres flavor.
#
# Required environment variables:
#   PGHOST              database server hostname
#   PGUSER              role with SELECT on source and CREATEDB on the cluster
#   PGPASSWORD          password for that role
#   SOURCE_DATABASE     existing database to clone from (e.g. myapp_staging)
#   TARGET_DATABASE     new database to create (must not yet exist)
#
# Optional environment variables:
#   PGPORT              default 5432
#   PGSSLMODE           e.g. require, prefer, disable
#   MAINTENANCE_DATABASE  default 'postgres' — DB used for the existence
#                       checks and CREATE DATABASE call. Managed services
#                       often expose a different default (e.g. DigitalOcean
#                       uses 'defaultdb'); the action forwards the dbname
#                       parsed from the admin URL when one is available.
#
# Exits 0 on success or when the target database already exists (idempotent).

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

kp_assert_identifier "$SOURCE_DATABASE" "SOURCE_DATABASE"
kp_assert_identifier "$TARGET_DATABASE" "TARGET_DATABASE"
kp_assert_identifier "$MAINTENANCE_DATABASE" "MAINTENANCE_DATABASE"

export PGHOST PGPORT PGUSER PGPASSWORD
[ -n "${PGSSLMODE:-}" ] && export PGSSLMODE

psql_scalar() {
  # -t: tuples only, -A: unaligned, -q: quiet — yields a single trimmed value.
  PGDATABASE="$MAINTENANCE_DATABASE" psql -v ON_ERROR_STOP=1 -tAq "$@"
}

# Idempotency: succeed if target already exists.
if [ -n "$(psql_scalar -c "SELECT 1 FROM pg_database WHERE datname = '${TARGET_DATABASE}' LIMIT 1" || true)" ]; then
  kp_log "Target database '${TARGET_DATABASE}' already exists — nothing to do."
  exit 0
fi

# Source must exist or we'd produce a confusing error from pg_dump.
if [ -z "$(psql_scalar -c "SELECT 1 FROM pg_database WHERE datname = '${SOURCE_DATABASE}' LIMIT 1" || true)" ]; then
  kp_die "Source database '${SOURCE_DATABASE}' does not exist on ${PGHOST}:${PGPORT}."
fi

kp_log "Creating empty target database '${TARGET_DATABASE}'…"
PGDATABASE="$MAINTENANCE_DATABASE" psql -v ON_ERROR_STOP=1 -q \
  -c "CREATE DATABASE \"${TARGET_DATABASE}\";"

kp_log "Dumping '${SOURCE_DATABASE}' → loading into '${TARGET_DATABASE}'…"
# --no-owner / --no-acl: sidestep ownership and GRANT statements that
#   reference roles that may not exist in the target (or that the connecting
#   role isn't allowed to assign on managed services).
# pg_dump runs against a live source — no need to terminate connections.
# pg_dump output is plain SQL; piping into psql restores schema + data.
# `set -o pipefail` (above) ensures a non-zero exit from either side fails.
pg_dump --no-owner --no-acl --dbname="$SOURCE_DATABASE" \
  | PGDATABASE="$TARGET_DATABASE" psql -v ON_ERROR_STOP=1 -q >/dev/null

kp_log "Clone complete."
