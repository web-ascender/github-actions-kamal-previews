#!/usr/bin/env bash
# Clone a SQLite database by copying its files (with a WAL checkpoint first).
#
# SQLite "databases" are just files on disk. The cloning trick is making sure
# in-flight writes are flushed before we copy:
#
#   1. Run `PRAGMA wal_checkpoint(TRUNCATE)` so WAL contents are merged into
#      the main database file.
#   2. Copy the main file (and the -shm/-wal files if present).
#
# This script is meant to run on the host where the SQLite file lives — most
# commonly inside the Docker volume directory. The recommended invocation is
# from the deploy host, with the volume bind-mounted into the script's
# working directory.
#
# Required environment variables:
#   SOURCE_PATH         absolute or relative path to the source DB file
#                       (e.g. /var/lib/myapp/storage/staging.sqlite3)
#   TARGET_PATH         absolute or relative path for the cloned DB file
#                       (e.g. /var/lib/myapp/storage/preview-foo.sqlite3)
#
# Optional environment variables:
#   ALSO_CLONE          space-separated list of suffixes to also copy
#                       alongside the main file. Useful if your app keeps
#                       solid_queue / solid_cache / solid_cable in separate
#                       SQLite files. Each suffix is appended to SOURCE_PATH
#                       and TARGET_PATH (both must end with the same base
#                       filename) — see docs/databases.md.
#
# Idempotent: succeeds and skips when TARGET_PATH already exists.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/identifier-safe.sh
source "${SCRIPT_DIR}/../lib/identifier-safe.sh"

: "${SOURCE_PATH:?SOURCE_PATH is required}"
: "${TARGET_PATH:?TARGET_PATH is required}"
ALSO_CLONE="${ALSO_CLONE:-}"

if [ ! -f "$SOURCE_PATH" ]; then
  kp_die "Source SQLite file '${SOURCE_PATH}' not found."
fi

if [ -f "$TARGET_PATH" ]; then
  kp_log "Target SQLite file '${TARGET_PATH}' already exists — nothing to do."
  exit 0
fi

# Make sure the target directory exists.
mkdir -p "$(dirname "$TARGET_PATH")"

kp_log "Checkpointing WAL on '${SOURCE_PATH}'…"
# `PRAGMA wal_checkpoint(TRUNCATE)` blocks until all writes are merged into
# the main DB file and the WAL is reset. Safe even if WAL isn't in use.
sqlite3 "$SOURCE_PATH" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null

kp_log "Copying main DB file…"
cp -p "$SOURCE_PATH" "$TARGET_PATH"

# Auxiliary files (-wal, -shm) — copy if they exist; their absence is fine.
for ext in -wal -shm; do
  if [ -f "${SOURCE_PATH}${ext}" ]; then
    cp -p "${SOURCE_PATH}${ext}" "${TARGET_PATH}${ext}"
  fi
done

# Companion DBs for solid_queue / solid_cache / solid_cable.
if [ -n "$ALSO_CLONE" ]; then
  for suffix in $ALSO_CLONE; do
    src="${SOURCE_PATH%.*}${suffix}.${SOURCE_PATH##*.}"
    tgt="${TARGET_PATH%.*}${suffix}.${TARGET_PATH##*.}"
    if [ -f "$src" ]; then
      kp_log "Copying companion DB '${src}' → '${tgt}'…"
      sqlite3 "$src" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
      cp -p "$src" "$tgt"
      for ext in -wal -shm; do
        [ -f "${src}${ext}" ] && cp -p "${src}${ext}" "${tgt}${ext}"
      done
    fi
  done
fi

kp_log "Clone complete."
