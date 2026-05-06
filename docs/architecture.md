# Architecture

feature-deploys is three layers stacked on top of standard Kamal 2 + GitHub
Actions primitives:

```
                     ┌─────────────────────────────────────┐
   Consumer's repo ─►│  .github/workflows/preview.yml      │
                     │  (calls web-ascender/github-actions-kamal-previews │
                     │   reusable workflow with `uses:`)   │
                     └─────────────────┬───────────────────┘
                                       │
                                       ▼
                     ┌─────────────────────────────────────┐
   Layer 1:          │  .github/workflows/preview.yml      │
   Reusable workflow │  (this repo) — orchestrates jobs    │
                     │  for deploy / teardown.             │
                     └─────────────────┬───────────────────┘
                                       │
                                       ▼
                     ┌─────────────────────────────────────┐
   Layer 2:          │  .github/actions/{setup,            │
   Composite actions │   generate-config, clone-database,  │
   (independently    │   deploy, teardown, drop-database,  │
    callable)        │   pr-comment, deployment-status}    │
                     └─────────────────┬───────────────────┘
                                       │
                                       ▼
                     ┌─────────────────────────────────────┐
   Layer 3:          │  lib/feature_deploys/* (Ruby)        │
   Plain code        │  scripts/{postgres,mysql,sqlite}/*   │
                     │  (Bash) + scripts/lib/                │
                     └─────────────────────────────────────┘
```

Each layer can be used directly: a sufficiently advanced consumer might
call the composite actions from their own workflow without going through
the reusable workflow, and a script-only consumer might shell out to
`bin/feature-deploys` from elsewhere.

## Layer 1: the reusable workflow

`.github/workflows/preview.yml` is the only thing most consumers touch.
It defines two jobs:

- `deploy` — runs on `pull_request` (opened/synchronize/reopened).
- `teardown` — runs on `pull_request` (closed) or `delete` (branch).

Concurrency is keyed by PR number / branch ref so multiple pushes to one
branch don't deploy in parallel. `cancel-in-progress` is `true` for
deploys (latest push wins) and `false` for teardowns.

The workflow checks out the consumer's repo (via `actions/checkout@v4`)
and *also* checks out this repo into a sibling subdirectory
(`.feature-deploys/`) at the same ref the consumer pinned. The composite
actions referenced as `./.feature-deploys/.github/actions/foo` are then
local to the runner.

The "self-checkout at the same ref" pattern uses `${{ github.workflow_ref }}`,
which for a reusable workflow contains the called workflow's full path
including its ref. Parsing it at the start of each job gives us the
`repo:ref` to feed to the second `actions/checkout`.

## Layer 2: composite actions

Each composite action under `.github/actions/<name>/action.yml` is a small,
focused unit:

| Action | Responsibility |
| --- | --- |
| `setup`              | Install Ruby (for our scripts) and Kamal (for deploys). Load SSH key into ssh-agent. Optionally install Buildx + GHA cache + registry login. |
| `generate-config`    | Wrap `bin/feature-deploys generate`. Sanitizes the branch name and writes `config/deploy.<slug>.yml` + secrets. |
| `clone-database`     | Upload the engine-specific clone script to the deploy host and run it (in a Docker container for postgres/mysql; directly for sqlite). |
| `deploy`             | Run `kamal lock release` then `kamal deploy -d <slug>`. |
| `teardown`           | Run `kamal lock release` then `kamal app remove -d <slug>`. Optionally clean up generated files. |
| `drop-database`      | Mirror of `clone-database` for the teardown side. |
| `deployment-status`  | Manage the GitHub Deployments API for the per-PR environment. |
| `pr-comment`         | Post-or-update a single rolling comment on the PR with status + URL. |

Each action is independently callable — for example, a consumer might call
just `clone-database` from a different workflow if they have their own
deploy logic.

## Layer 3: scripts and the Ruby library

The Ruby library at `lib/feature_deploys/` is **stdlib-only** — no Bundler,
no Rails. Two classes:

- `Namer` — sanitizes a branch name into `slug` (DNS-safe) and `db_slug`
  (SQL-identifier-safe). Strips common Git Flow prefixes by default.
- `ConfigGenerator` — reads the base Kamal deploy file, applies
  template-driven overrides, writes `config/deploy.<dest>.yml`.

The CLI (`bin/feature-deploys`) wraps both with `generate` and `slugify`
subcommands. It writes both a JSON summary to stdout AND key/value pairs
to `$GITHUB_OUTPUT` when running inside a GitHub Actions step.

The shell scripts under `scripts/` are the database adapters:

| Script | Engine |
| --- | --- |
| `scripts/postgres/{clone,drop}.sh` | PostgreSQL via `CREATE DATABASE … TEMPLATE` |
| `scripts/mysql/{clone,drop}.sh`    | MySQL via `mysqldump | mysql` |
| `scripts/sqlite/{clone,drop}.sh`   | SQLite via `cp` (with WAL checkpoint first) |
| `scripts/lib/identifier-safe.sh`   | Shared helpers (identifier validation, logging) |

The scripts are designed to run inside the corresponding official Docker
image (`postgres:16-alpine`, `mysql:8.4`) so the deploy host doesn't need
client tooling installed. Identifier inputs are validated against
`^[A-Za-z_][A-Za-z0-9_]{0,62}$` to prevent SQL injection.

## Data flow

A typical deploy run:

```
PR opened
  │
  ▼ (GH Actions trigger)
deploy job
  │
  ├─ checkout caller repo
  ├─ checkout feature-deploys at matching ref
  ├─ setup (Ruby, Kamal, SSH agent, Buildx)
  ├─ generate-config
  │     │
  │     ├─ Namer: feature/checkout-rewrite → slug=checkout-rewrite, db_slug=checkout_rewrite
  │     ├─ ConfigGenerator: writes config/deploy.checkout-rewrite.yml + .kamal/secrets.checkout-rewrite
  │     └─ outputs: destination, proxy_host, database_name, …
  │
  ├─ deployment-status (state=created)
  ├─ pr-comment (state=building)
  │
  ├─ clone-database
  │     │
  │     ├─ scp scripts → deploy host
  │     └─ ssh deploy@host → docker run postgres:16-alpine bash /work/postgres/clone.sh
  │           (CREATE DATABASE myapp_checkout_rewrite TEMPLATE myapp_staging)
  │
  ├─ deploy
  │     │
  │     ├─ kamal lock release -d checkout-rewrite
  │     └─ kamal deploy -d checkout-rewrite
  │           ├─ build image (with cache from GHA)
  │           ├─ push to GHCR
  │           └─ ssh to deploy host, run new container, register with kamal-proxy
  │
  ├─ deployment-status (state=success, environment_url=…)
  └─ pr-comment (state=ready)
```

Teardown runs the same shape in reverse: kamal app remove, drop database,
deployment-status (removed), pr-comment (removed).

## Why these choices?

A few of the decisions are non-obvious; this section captures the tradeoffs.

### Reusable workflow over composite action at root

GitHub composite actions can call other composite actions in the same repo
via `uses: ./<path>`, but the resolution semantics are subtle and have been
the subject of [open issues](https://github.com/actions/runner/issues/1348).
A reusable workflow with explicit `actions/checkout` at the start has
well-defined semantics — at the cost of a few extra steps per run.

### Database clone over SSH instead of from the runner

The runner doesn't typically have network access to the database server
(databases live on a private subnet). The deploy host does, since it has to
reach the DB to actually run the app. So we ssh to the deploy host and run
the script there. This sidesteps VPN setup, restrictive security groups,
and the "is my runner's IP whitelisted" question.

### Docker for database clients

The deploy host probably doesn't have `psql` / `mysqldump` installed — and
shouldn't be expected to. By running the clone script inside the official
DB image (`postgres:16-alpine`, `mysql:8.4`), we get the right tools at the
right version with no host-side dependency.

### One Kamal `service:` per PR

Kamal 2's `kamal-proxy` multiplexes requests to many backend containers on
one host based on the `Host` header. Each per-PR Kamal `service:` deploys
its own container; the proxy routes by `proxy.host:`. That gives us
unlimited preview apps on a single $5 host (until RAM or CPU caps you).

### Branch-name slugs, not PR numbers

Using PR numbers would be cleaner for URLs (`pr-123.preview.example.com`)
but the `delete` event for branches deleted *outside* of a closed PR
doesn't carry a PR number. The branch name is the common denominator
across all three lifecycle triggers (open, close, delete).

If you prefer PR numbers, set `domain-label-pattern: "pr-{slug}"` and
ensure your branches are named `pr-NNN-...` (or override the slug
substitution with a custom pattern).

### Stdlib-only Ruby library

The Ruby library has no gem dependencies because it has to run before
Bundler does. In particular, the per-PR `Gemfile.lock` might lock different
gem versions than the runner has installed; rather than introduce a
version coordination problem, we use only Ruby stdlib (YAML, FileUtils,
JSON, OptionParser).

### Top-down vs. bottom-up validation

Identifier validation lives in the *shell scripts*, not the Ruby library.
The Ruby library sanitizes its outputs to a stricter subset, but the shell
scripts don't trust that — they validate again before interpolating into
SQL. This means "you can run the scripts standalone with arbitrary inputs
and still be safe."
