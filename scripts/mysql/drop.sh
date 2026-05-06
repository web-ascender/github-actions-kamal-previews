#!/usr/bin/env bash
# Drop a MySQL database (used during PR teardown).
#
# Required environment variables:
#   MYSQL_HOST, MYSQL_USER, MYSQL_PASSWORD, TARGET_DATABASE
#
# Optional:
#   MYSQL_PORT (default 3306), MYSQL_SSL_MODE
#
# Idempotent: exits 0 whether the database existed or not.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/identifier-safe.sh
source "${SCRIPT_DIR}/../lib/identifier-safe.sh"

: "${MYSQL_HOST:?MYSQL_HOST is required}"
: "${MYSQL_USER:?MYSQL_USER is required}"
: "${MYSQL_PASSWORD:?MYSQL_PASSWORD is required}"
: "${TARGET_DATABASE:?TARGET_DATABASE is required}"

MYSQL_PORT="${MYSQL_PORT:-3306}"
kp_assert_identifier "$TARGET_DATABASE" "TARGET_DATABASE"

mysql_args=(-h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD")
[ -n "${MYSQL_SSL_MODE:-}" ] && mysql_args+=(--ssl-mode="$MYSQL_SSL_MODE")

kp_log "Dropping database '${TARGET_DATABASE}' (if it exists)…"
mysql "${mysql_args[@]}" -e "DROP DATABASE IF EXISTS \`${TARGET_DATABASE}\`;"
kp_log "Drop complete."
