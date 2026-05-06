#!/usr/bin/env bash
# Drop (delete) a SQLite database file and its WAL/SHM siblings.
#
# Required environment variables:
#   TARGET_PATH         path to the SQLite DB file to remove
#
# Optional:
#   ALSO_DROP           space-separated suffixes of companion DB files to
#                       also remove (e.g. "_queue _cache _cable").
#
# Idempotent.

set -euo pipefail

: "${TARGET_PATH:?TARGET_PATH is required}"
ALSO_DROP="${ALSO_DROP:-}"

remove_db() {
  local base="$1"
  for suffix in "" "-wal" "-shm"; do
    if [ -e "${base}${suffix}" ]; then
      echo "[feature-deploys] Removing ${base}${suffix}"
      rm -f "${base}${suffix}"
    fi
  done
}

remove_db "$TARGET_PATH"

if [ -n "$ALSO_DROP" ]; then
  for suffix in $ALSO_DROP; do
    companion="${TARGET_PATH%.*}${suffix}.${TARGET_PATH##*.}"
    remove_db "$companion"
  done
fi

echo "[feature-deploys] Drop complete."
