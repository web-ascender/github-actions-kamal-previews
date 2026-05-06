# kamal-previews

GitHub-Actions-driven preview environments for Rails apps deployed with
[Kamal 2](https://kamal-deploy.org). Open a PR, get a fresh app at a unique
URL with a freshly cloned staging database. Close the PR, everything goes
away.

```
Pull Request opened ───▶ web-ascender/github-actions-kamal-previews ─┬─▶ kamal deploy -d <slug>
                                                       ├─▶ clone staging DB → myapp_<slug>
                                                       ├─▶ post URL on PR comment
                                                       └─▶ register GitHub Deployment

Pull Request closed ───▶ web-ascender/github-actions-kamal-previews ─┬─▶ kamal app remove -d <slug>
                                                       ├─▶ drop database myapp_<slug>
                                                       ├─▶ update PR comment
                                                       └─▶ deactivate GitHub Deployment
```

## Why

Rails + Kamal is a great combination, but Kamal alone doesn't ship with a
"review apps" / "preview environments" feature out of the box the way
Heroku or Render do. This repo packages the missing piece: one composite
action that any Kamal-deployed Rails app can adopt in a single workflow
step.

## What you get

- **One Kamal service per PR**, deployed to your existing staging host
  (multiple feature apps coexist on one server via `kamal-proxy`).
- **Database clone per PR.** PostgreSQL, MySQL, and SQLite all supported.
- **Full lifecycle.** Deploys on PR open/sync, tears down on PR close and
  on branch delete.
- **Native GitHub UX.** Deployments API integration, transient environment,
  rolling status comment on the PR with the live URL.
- **Sweeper** that reconciles orphaned deployments daily so nothing leaks.
- **Resource caps + concurrency caps + branch filter** to bound preview
  cost. (Scale-to-zero is on the upstream Kamal roadmap; see
  [`docs/resource-limits.md`](docs/resource-limits.md).)
- **No Ruby gem in your app.** Pure GitHub Action — invoke with one
  `uses:` line.

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

concurrency:
  group: kamal-previews-${{ github.event.pull_request.number || github.event.ref || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' && github.event.action != 'closed' }}

jobs:
  preview:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # Optional: open a WireGuard tunnel if your deploy host is private.
      # WireGuard and kamal-previews are independent concerns — compose
      # them as sibling steps. Drop this step if your host is public.
      - uses: <your-vpn-action>@v1
        with:
          private-key:  ${{ secrets.VPN_PRIVATE_KEY }}
          public-key:   ${{ secrets.VPN_PUBLIC_KEY }}
          interface-ip: "10.1.1.100/24"
          endpoint:     "vpn.example.com:51820"
          routes:       '["203.0.113.42"]'

      - uses: web-ascender/github-actions-kamal-previews@v1
        with:
          base-deploy-file:    config/deploy.staging.yml
          base-secrets-file:   .kamal/secrets.staging
          domain-suffix:       preview.example.com
          deploy-host:         staging.example.com
          database-engine:     postgres
          databases: |
            DATABASE_NAME=myapp_staging:myapp_{db_slug}
        env:
          SSH_PRIVATE_KEY:  ${{ secrets.DEPLOY_SSH_KEY }}
          # No DB credentials needed here — the action sources
          # base-secrets-file and reads DATABASE_URL for the admin
          # connection. Override with the DATABASE_ADMIN_URL secret if
          # the staging app role lacks CREATEDB.
```

The repo-level GitHub Actions secrets the workflow expects:

| Secret | When |
| --- | --- |
| `DEPLOY_SSH_KEY`     | Always — the deploy host SSH key. |
| `DATABASE_ADMIN_URL` | Only if the URL exposed by your `base-secrets-file` doesn't have CREATEDB. Format: `postgres://admin:secret@host:5432/postgres?sslmode=verify-full`. |
| `VPN_PRIVATE_KEY`, `VPN_PUBLIC_KEY` | Only if pairing with the WireGuard step above. |

Add them under Settings → Secrets and variables → Actions. The first PR
you open after merging the workflow file will provision a preview
environment.

See [`docs/getting-started.md`](docs/getting-started.md) for the full
walkthrough including DNS, TLS, secrets, and host setup.

## Reusable-workflow form (advanced)

Prefer the reusable workflow form
(`uses: web-ascender/github-actions-kamal-previews/.github/workflows/preview.yml@v1`)
when you want job-level features like matrix-fanned parallel orphan
cleanup or GitHub's job-level concurrency UI. It does NOT support
WireGuard pairing — workflows can't host sibling steps the way actions
can — so private-host setups must use the composite action form above.
See [`examples/README.md`](examples/README.md) for the comparison.

## Architecture at a glance

The work splits into four layers:

1. **Top-level composite action** (`action.yml`) — the simple
   `uses: web-ascender/github-actions-kamal-previews@v1` entry point. Auto-dispatches
   deploy vs. teardown based on the triggering event.
2. **Reusable workflow** (`.github/workflows/preview.yml`) — alternate
   entry point for adopters who want job-level features (matrix
   parallelism, separate concurrency groups for deploy vs. teardown).
3. **Sub-composite actions** (`.github/actions/*/action.yml`) — the
   building blocks both entry points share: `setup`, `generate-config`,
   `clone-database`, `deploy`, `teardown`, `pr-comment`,
   `deployment-status`. Independently usable.
4. **Stdlib-only Ruby library** (`lib/kamal_previews/`) — branch-name
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
- [Resource limits](docs/resource-limits.md) — memory / CPU caps,
  branch-pattern filtering, max-concurrent-previews cap, and notes on
  the scale-to-zero gap.
- [Reference](docs/reference.md) — every input, output, and secret the
  reusable workflow consumes.
- [Troubleshooting](docs/troubleshooting.md) — common failure modes.

## License

MIT. See [LICENSE](LICENSE).
