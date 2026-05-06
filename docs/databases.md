# Database engines

kamal-previews ships built-in support for PostgreSQL, MySQL, and SQLite.
This page covers engine-specific notes, sanitization, and the in-container
clone alternative.

## PostgreSQL

**Default mechanism:** `CREATE DATABASE <target> TEMPLATE <source>`.

This is fast (typically <5s for a few-GB database, milliseconds on
PostgreSQL 18+ with `file_copy_method = clone` on a reflink-capable
filesystem) but has a constraint: **PostgreSQL must have no active
connections to the source database** at the moment of clone. The script
calls `pg_terminate_backend` to evict existing connections, then waits up
to `DISCONNECT_TIMEOUT` seconds (default 15) for them to actually drop.

If your staging environment has long-running connections that auto-reconnect,
you may need to:

1. Increase `DISCONNECT_TIMEOUT` via the `pg-` knobs (planned input,
   currently the script-level default).
2. Use a dedicated "template" database that nothing else connects to, and
   refresh it from staging on a schedule. Then point each `databases:` entry's source
   at the template database, not at staging.

**Permissions.** The role in your `DATABASE_ADMIN_URL` (or the
`DATABASE_URL` resolved from `base-secrets-file`) needs:

- `CREATEDB` to create new databases.
- `CONNECT` privilege on the source database.
- Login rights on the maintenance database (`postgres` by default; override
  with the `MAINTENANCE_DATABASE` env var on the script).

**Cleanup.** `DROP DATABASE IF EXISTS <target> WITH (FORCE)` — `FORCE`
terminates remaining connections automatically.

## MySQL

**Default mechanism:** `mysqldump --single-transaction | mysql`.

This works on any MySQL 5.7+ / 8.x server without special configuration. It
is, however, **slower** than the postgres path — proportional to the size
of the dump. Plan for tens of seconds to several minutes on dumps in the
GB range.

**Faster alternative:** `mysqlsh util.dumpInstance` + `loadDump`. Parallel
by default and 4–8× faster than `mysqldump`. Switch by overriding the
`docker-image` input on the `clone-database` action to
`mysql/mysql-shell:8.4` and customizing the script — see
[`scripts/mysql/clone.sh`](../scripts/mysql/clone.sh) for the integration
point. (We're considering shipping a second variant; PRs welcome.)

**Permissions.** The user in `mysql-user` needs:

- `CREATE` / `DROP` on `*.*` (or at least on the per-PR database wildcard).
- `SELECT` on the source database (and `SHOW VIEW`, `LOCK TABLES` if you
  enable `--lock-tables`).
- For `--routines --triggers --events` (which we pass), needs `EXECUTE`
  permission and access to the `mysql` system schema.

## SQLite

**Default mechanism:** copy the file (after `PRAGMA wal_checkpoint(TRUNCATE)`).

SQLite doesn't have a concept of separate "users" or "permissions" at the
database engine level — files have unix permissions and that's it. The
script needs to be able to:

- Read the source files (`<source>.sqlite3`, plus `-wal` and `-shm` if
  present).
- Write to the target directory.

**Companion files.** Apps that use Solid Queue / Solid Cache / Solid Cable
on SQLite typically have separate database files for each. List their
suffixes via the `sqlite-also-clone` input, e.g.
`sqlite-also-clone: "_queue _cache _cable"`. Each suffix is appended to
the basename, so `staging.sqlite3` plus `_queue` = `staging_queue.sqlite3`.

**Volume layout.** The clone happens in a directory on the deploy host —
typically a Docker volume mounted into both the staging app and the per-PR
app. The cleanest layout:

```
/var/lib/myapp/storage/                  ← Docker volume, bind-mounted
├── staging.sqlite3                      ← read-only template (staging app uses this)
├── staging_queue.sqlite3
├── staging_cache.sqlite3
├── staging_cable.sqlite3
├── preview-checkout-rewrite.sqlite3      ← per-PR clone
├── preview-checkout-rewrite_queue.sqlite3
└── …
```

Per-PR Kamal config sets `DATABASE_URL` (or templates `database.yml`) to
point at the per-PR file. Use the `FEATURE_BRANCH_SLUG` env var that
kamal-previews injects:

```yaml
# config/database.yml in your app
production:
  primary:
    adapter: sqlite3
    database: <%= ENV.fetch("DATABASE_URL", "storage/production.sqlite3") %>
```

…and in the workflow:

```yaml
env-overrides: |
  DATABASE_URL=storage/preview-{{slug}}.sqlite3
```

## In-container clone (alternative pattern)

The default architecture clones the database from the GitHub runner via
SSH to the deploy host, *before* running `kamal deploy`. An alternative
pattern (which the seed implementation in kamal-previews uses) is
to do the clone *inside the per-PR app's container at boot*, via the
Dockerfile's entrypoint.

Pros:
- The runner doesn't need any DB-clone-related secrets.
- The clone code lives next to the app and can use Rails / app-specific
  utilities.

Cons:
- Clone failures are reported as "deployed but the app crashed during boot"
  instead of "deploy failed before starting the app".
- Adds Rails-specific code to your Dockerfile/entrypoint.

To use this mode:

1. Set `database-engine: none` in the workflow inputs (so kamal-previews
   doesn't run the host-side clone).
2. Add a snippet to your `bin/docker-entrypoint`:

   ```bash
   if [ "${FEATURE_BRANCH}" = "true" ] && [ -n "${DATABASE_NAME}" ]; then
     ./bin/rails "db:clone[${BASE_DATABASE},${DATABASE_NAME}]"
   fi
   ```

3. Add a `db:clone` rake task to your app — see
   [`kamal-previews:lib/tasks/db.rake`](https://github.com/...)
   for a working PostgreSQL example.

The `FEATURE_BRANCH=true`, `DATABASE_NAME`, `FEATURE_BRANCH_SLUG`, and
`FEATURE_BRANCH_DB_SLUG` env vars are set automatically by the
`generate-config` action regardless of `database-engine`.

## Sanitization (PII)

If your staging database contains real user data (it shouldn't, but
sometimes does), you'll want to sanitize it before previews. Two
recommended approaches:

### Pre-sanitized template

Maintain a separate `myapp_staging_sanitized` database, refreshed from
staging nightly via your existing data-pipeline tooling
([PostgreSQL Anonymizer](https://postgresql-anonymizer.readthedocs.io/),
[Replibyte](https://github.com/Qovery/Replibyte), or your own SQL
masking). Point each `databases:` entry's source at the sanitized version.

### Post-clone sanitization hook

After the clone but before the app boots, run sanitization SQL against the
new per-PR database. The cleanest hook is a Kamal `pre-deploy` hook
(`.kamal/hooks/pre-deploy`) that's only active for non-staging
destinations:

```bash
#!/usr/bin/env bash
set -euo pipefail
[ "$KAMAL_DESTINATION" = "staging" ] && exit 0
[ "$KAMAL_DESTINATION" = "production" ] && exit 0
psql "$PG_URL_FOR_FEATURE_BRANCH" < db/sanitize_for_preview.sql
```

Make sure `db/sanitize_for_preview.sql` is idempotent (use `UPDATE`s, not
`DELETE`s) so re-running on the same branch doesn't break things.

## Multi-database Rails setups

If your app uses Rails 6.1+ multi-database with separate primary + cache +
cable + queue databases (typical for Solid Queue / Solid Cable / Solid
Cache), the postgres scripts can clone all four — but you have to invoke
them once per database. Easiest pattern: drop into a small wrapper rake
task in your app that loops over the configured databases, and run it from
the workflow. Or set `database-engine: none` and write the clone in your
entrypoint as described above.

A built-in "clone all configured databases" mode is on the roadmap.
