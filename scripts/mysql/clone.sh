#!/usr/bin/env bash
# Clone a MySQL database using mysqldump | mysql.
#
# Designed to run inside the official `mysql:N` Docker image. Larger databases
# can swap this for `mysqlsh util.dumpInstance / loadDump`, which is
# significantly faster but requires the heavier `mysql/mysql-shell` image.
# See `docs/databases.md` for that mode.
#
# Required environment variables:
#   MYSQL_HOST          database server hostname
#   MYSQL_USER          role with SELECT on source and CREATE on target
#   MYSQL_PASSWORD      password for that role
#   SOURCE_DATABASE     existing database to clone from
#   TARGET_DATABASE     new database to create
#
# Optional:
#   MYSQL_PORT          default 3306
#   MYSQL_SSL_MODE      passed to --ssl-mode (e.g. REQUIRED, DISABLED)
#
# Idempotent: skips if target already exists.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/identifier-safe.sh
source "${SCRIPT_DIR}/../lib/identifier-safe.sh"

: "${MYSQL_HOST:?MYSQL_HOST is required}"
: "${MYSQL_USER:?MYSQL_USER is required}"
: "${MYSQL_PASSWORD:?MYSQL_PASSWORD is required}"
: "${SOURCE_DATABASE:?SOURCE_DATABASE is required}"
: "${TARGET_DATABASE:?TARGET_DATABASE is required}"

MYSQL_PORT="${MYSQL_PORT:-3306}"
fd_assert_identifier "$SOURCE_DATABASE" "SOURCE_DATABASE"
fd_assert_identifier "$TARGET_DATABASE" "TARGET_DATABASE"

mysql_args=(-h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD")
[ -n "${MYSQL_SSL_MODE:-}" ] && mysql_args+=(--ssl-mode="$MYSQL_SSL_MODE")

# Idempotency: succeed if target already exists.
target_exists="$(mysql "${mysql_args[@]}" -N -e "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${TARGET_DATABASE}' LIMIT 1" || true)"
if [ -n "$target_exists" ]; then
  fd_log "Target database '${TARGET_DATABASE}' already exists — nothing to do."
  exit 0
fi

# Source must exist.
source_exists="$(mysql "${mysql_args[@]}" -N -e "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${SOURCE_DATABASE}' LIMIT 1" || true)"
if [ -z "$source_exists" ]; then
  fd_die "Source database '${SOURCE_DATABASE}' does not exist on ${MYSQL_HOST}:${MYSQL_PORT}."
fi

fd_log "Creating empty target database '${TARGET_DATABASE}'…"
mysql "${mysql_args[@]}" -e "CREATE DATABASE \`${TARGET_DATABASE}\`;"

fd_log "Dumping '${SOURCE_DATABASE}' → loading into '${TARGET_DATABASE}'…"
# --single-transaction = consistent dump without locking InnoDB tables.
# --routines, --triggers, --events = include stored programs.
# --set-gtid-purged=OFF = avoid embedding source GTID state into the dump.
# --column-statistics=0 = compatibility with non-Oracle MySQL forks.
mysqldump "${mysql_args[@]}" \
  --single-transaction \
  --routines --triggers --events \
  --column-statistics=0 \
  --set-gtid-purged=OFF \
  "$SOURCE_DATABASE" \
  | mysql "${mysql_args[@]}" "$TARGET_DATABASE"

fd_log "Clone complete."
