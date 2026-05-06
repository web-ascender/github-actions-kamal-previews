# feature-deploys

GitHub-Actions-driven preview environments for Rails apps deployed with
[Kamal 2](https://kamal-deploy.org). Open a PR, get a fresh app at a unique
URL with a freshly cloned staging database. Close the PR, everything goes
away.

```
Pull Request opened ───▶ feature-deploys reusable workflow ─┬─▶ kamal deploy -d pr-123
                                                            ├─▶ clone staging DB → myapp_pr_123
                                                            ├─▶ post URL on PR comment
                                                            └─▶ register GitHub Deployment

Pull Request closed ───▶ feature-deploys reusable workflow ─┬─▶ kamal app remove -d pr-123
                                                            ├─▶ drop database myapp_pr_123
                                                            ├─▶ update PR comment
                                                            └─▶ deactivate GitHub Deployment
```

## Why

Rails + Kamal is a great combination, but Kamal alone doesn't ship with a
"review apps" / "preview environments" feature out of the box the way Heroku
or Render do. This repo packages the missing piece: a small reusable workflow
plus a handful of composite actions that any Kamal-deployed Rails app can
adopt with about ten lines of YAML.

## What you get

- **One Kamal service per PR**, deployed to your existing staging host
  (multiple feature apps can coexist on one server thanks to `kamal-proxy`).
- **Database clone per PR.** PostgreSQL, MySQL, and SQLite all supported.
  Postgres uses `CREATE DATABASE … TEMPLATE`; MySQL uses
  `mysqlsh util.dumpInstance / loadDump`; SQLite copies the file (after
  checkpointing the WAL).
- **Full lifecycle.** Deploys on PR open/sync, tears down on PR close and on
  branch delete.
- **Native GitHub UX.** Deployments API integration, transient environment,
  rolling status comment on the PR with the live URL.
- **Sweeper** that reconciles orphaned deployments weekly so nothing leaks.
- **No Ruby gem to install in your app.** Everything lives in this repo and
  is invoked via `uses: web-ascender/github-actions-kamal-previews/...@v1`.

## Quick start

In your Rails app's repo, drop one workflow file:

```yaml
# .github/workflows/preview.yml
name: Preview environment

on:
  pull_request:
    types: [opened, synchronize, reopened, closed]
  delete:

permissions:
  contents: read
  packages: write          # GHCR push
  pull-requests: write     # PR comments
  deployments: write       # Deployments API
  id-token: write          # OIDC, optional

jobs:
  preview:
    uses: web-ascender/github-actions-kamal-previews/.github/workflows/preview.yml@v1
    with:
      base-deploy-file:    config/deploy.staging.yml
      base-secrets-file:   .kamal/secrets.staging
      domain-suffix:       preview.example.com
      database-engine:     postgres
      database-template:   myapp_staging
      database-name-pattern: "myapp_{slug}"
    secrets: inherit
```

The repo-level GitHub Actions secrets the workflow expects (declared in
`SHOUTING_CASE` so `secrets: inherit` matches them):

| Secret | When |
| --- | --- |
| `SSH_PRIVATE_KEY` | Always — the deploy host SSH key. |
| `PG_HOST`, `PG_USER`, `PG_PASSWORD` | When `database-engine: postgres`. |
| `MYSQL_HOST`, `MYSQL_USER`, `MYSQL_PASSWORD` | When `database-engine: mysql`. |

Add them under Settings → Secrets and variables → Actions. The first PR
you open after merging the workflow file will provision a preview
environment.

See [`docs/getting-started.md`](docs/getting-started.md) for the full
walkthrough including DNS, TLS, secrets, and host setup.

## Architecture at a glance

The work splits into three layers:

1. **Reusable workflow** (`.github/workflows/preview.yml`) — single entry
   point. Decides whether to deploy or tear down based on the triggering
   event, then dispatches to the right composite action.
2. **Composite actions** (`.github/actions/*/action.yml`) — small,
   independently usable units (`setup`, `generate-config`,
   `clone-database`, `deploy`, `teardown`, `pr-comment`). Each is a plain
   shell or `uses:` orchestrator with no Docker action machinery.
3. **Stdlib-only Ruby library** (`lib/feature_deploys/`) — branch-name
   sanitization and Kamal config generation. Runs on any Ruby ≥ 3.0
   without Bundler.

The database engines are pluggable shell scripts under
`scripts/{postgres,mysql,sqlite}/` invoked by the `clone-database` and
`drop-database` composite actions. Adding a new engine is one new directory.

See [`docs/architecture.md`](docs/architecture.md) for a deeper look.

## Compatibility

- **Kamal 2.x.** Kamal 1 is not supported.
- **Rails 7.1+** is the tested baseline. Earlier Rails works as long as your
  Dockerfile and Kamal config are Kamal-2-compatible.
- **GitHub Actions** runners — `ubuntu-latest` is the default; the workflow
  is portable.
- **Databases:** PostgreSQL 14+, MySQL 8.0+, SQLite 3.

## Documentation

- [Getting started](docs/getting-started.md) — adoption walkthrough.
- [Architecture](docs/architecture.md) — how the pieces fit together.
- [Databases](docs/databases.md) — engine-specific notes, sanitization
  hooks, and clone modes.
- [Secrets](docs/secrets.md) — Kamal `kamal secrets` integration with
  1Password, AWS, GCP, Doppler, etc.
- [DNS and TLS](docs/dns-and-tls.md) — wildcard DNS, per-host vs. wildcard
  certs, the cookie-domain footgun.
- [Reference](docs/reference.md) — every input, output, and secret the
  reusable workflow consumes.
- [Troubleshooting](docs/troubleshooting.md) — common failure modes.

## License

MIT. See [LICENSE](LICENSE).
