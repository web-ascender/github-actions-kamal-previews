#!/usr/bin/env bash
# Shared helpers for the database scripts. Source this from a sibling script.
# These helpers are intentionally tiny and POSIX-friendly except for the use
# of bash regex matching, which the official postgres/mysql Docker images
# already include.

# Validate that a string is safe to interpolate into a SQL identifier
# position WITHOUT quoting. Rejects anything outside [A-Za-z0-9_] and anything
# that doesn't start with a letter or underscore. This is intentionally
# stricter than what PostgreSQL/MySQL actually accept; we only ever generate
# identifiers from `db_slug` (which uses the same alphabet), so the tighter
# rule catches surprises like injected SQL fragments.
kp_assert_identifier() {
  local name="$1"
  local label="${2:-identifier}"

  if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]]; then
    echo "[kamal-previews] Refusing to use ${label} '${name}' — must match ^[A-Za-z_][A-Za-z0-9_]{0,62}$" >&2
    return 1
  fi
}

kp_log() {
  echo "[kamal-previews] $*"
}

kp_die() {
  echo "[kamal-previews] $*" >&2
  exit 1
}
