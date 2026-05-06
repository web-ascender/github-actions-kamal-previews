# Getting started

This guide walks through adopting feature-deploys in an existing Rails app
that already deploys to staging via Kamal 2. By the end you'll have a
preview environment automatically created on every pull request.

The example uses PostgreSQL on a single shared deploy host
(`staging.example.com`) and DNS suffix `preview.example.com`. Substitute
your own values throughout.

## Prerequisites

You need:

1. **A Kamal-deployed staging app**, with `config/deploy.staging.yml` and
   (optionally) `.kamal/secrets.staging`. feature-deploys uses these as the
   template for each per-PR app — most settings (image, registry, builder,
   accessories, env tags) are inherited verbatim.
2. **A staging host** that can run multiple Kamal apps simultaneously.
   Each preview gets its own `kamal-proxy`-routed service on the same host.
3. **A wildcard DNS record** `*.preview.example.com → <staging host IP>` (or
   a CNAME to a load balancer that points at the staging host).
4. **An SSH key** that can `ssh deploy@<staging host>` and run `docker`.
   This is the same key Kamal uses to deploy.
5. **Database admin credentials** that can `CREATE DATABASE` on your
   staging DB cluster. Same cluster as staging is fine.

## Step 1: Pick the URL pattern

Decide what hostnames preview apps should get. The default is
`<branch-slug>.preview.example.com`. Examples:

| Branch | Slug | URL |
| --- | --- | --- |
| `feature/checkout-rewrite` | `checkout-rewrite` | `https://checkout-rewrite.preview.example.com` |
| `fix/123-bad-redirect`     | `123-bad-redirect` | `https://123-bad-redirect.preview.example.com` |
| `bug/very-long-branch-name-that-keeps-going-forever` | first 50 chars (no trailing `-`) | … |

Run `bin/feature-deploys slugify --branch <name>` from a clone of this repo
to preview the slug for any branch name. If you want a different URL shape
(e.g. `pr-123.preview.example.com`), see the
[`domain-label-pattern`](reference.md#domain-label-pattern) reference.

## Step 2: Configure DNS

Add a wildcard record to your DNS:

```
*.preview.example.com.  IN  A   <staging host IP>
```

If you proxy through Cloudflare, set encryption mode to **Full (strict)** —
`kamal-proxy` will request HTTP-01 Let's Encrypt certs per host.

> **Cookie-domain footgun.** If your app sets `Domain=.preview.example.com`
> on its session cookie, every preview environment will share cookies with
> every other preview environment. Don't do that. See
> [`docs/dns-and-tls.md`](dns-and-tls.md).

## Step 3: Make sure your base `deploy.staging.yml` is preview-friendly

Most Kamal staging configs work out of the box. Two things to double-check:

1. **`proxy:` is configured with `host:` set.** This is what tells
   `kamal-proxy` to multiplex by hostname. feature-deploys overrides
   `proxy.host` in each per-PR config but leaves the rest of the proxy block
   alone. Recommended: enable SSL for the proxy.

   ```yaml
   proxy:
     host: staging.example.com
     ssl: true
     response_timeout: 60
   ```

2. **Your image is buildable from a clean checkout.** feature-deploys runs
   `kamal deploy` from the runner, which does a fresh clone. If you
   currently rely on uncommitted changes (e.g. via `builder.context: "."`
   in your staging config), set the `builder-context` input to override.

## Step 4: Make your app database-name-aware

The per-PR app needs to know which database to connect to. feature-deploys
sets `DATABASE_NAME` (and `FEATURE_BRANCH_SLUG`, `FEATURE_BRANCH_DB_SLUG`,
`FEATURE_BRANCH_LABEL`) on the per-PR app's environment. The simplest
hookup is a one-liner in `config/database.yml`:

```yaml
default: &default
  adapter: postgresql

staging:
  primary:
    <<: *default
    database: <%= ENV.fetch("DATABASE_NAME") { "myapp_staging" } %>
    username: <%= ENV.fetch("DB_USER") %>
    password: <%= ENV.fetch("DB_PASSWORD") %>
    host:     <%= ENV.fetch("DB_HOST") %>
```

If you also use SolidQueue / SolidCache / SolidCable on Postgres, give them
their own per-PR databases the same way:

```yaml
staging:
  primary: { ..., database: <%= ENV.fetch("DATABASE_NAME") %> }
  cache:   { ..., database: <%= ENV.fetch("DATABASE_NAME") %>_cache }
  cable:   { ..., database: <%= ENV.fetch("DATABASE_NAME") %>_cable }
  queue:   { ..., database: <%= ENV.fetch("DATABASE_NAME") %>_queue }
```

When configured this way, feature-deploys can clone all four. See
[`docs/databases.md`](databases.md#multi-database-rails-setups) for the
clone hook.

## Step 5: Add the preview workflow

Copy [`examples/postgres/preview.yml`](../examples/postgres/preview.yml)
into your repo at `.github/workflows/preview.yml` and edit the `with:`
and `env:` blocks. The minimum-viable shape:

```yaml
name: Preview environment

on:
  pull_request:
    types: [opened, synchronize, reopened, closed]
  delete:

permissions:
  contents: read
  packages: write
  pull-requests: write
  deployments: write

concurrency:
  group: feature-deploys-${{ github.event.pull_request.number || github.event.ref || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' && github.event.action != 'closed' }}

jobs:
  preview:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # Optional: open a WireGuard tunnel before feature-deploys runs.
      # Skip this step if your deploy host is publicly addressable.
      - uses: <your-vpn-action>@v1
        with:
          private-key:  ${{ secrets.VPN_PRIVATE_KEY }}
          public-key:   ${{ secrets.VPN_PUBLIC_KEY }}
          interface-ip: "10.1.1.100/24"
          endpoint:     "vpn.example.com:51820"
          routes:       '["203.0.113.42"]'

      - uses: web-ascender/feature-deploys@v1
        with:
          base-deploy-file:        config/deploy.staging.yml
          base-secrets-file:       .kamal/secrets.staging
          domain-suffix:           preview.example.com
          deploy-host:             staging.example.com
          database-engine:         postgres
          database-template:       myapp_staging
          database-name-pattern:   "myapp_{db_slug}"
        env:
          SSH_PRIVATE_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
          PG_HOST:         ${{ secrets.PG_HOST }}
          PG_USER:         ${{ secrets.PG_USER }}
          PG_PASSWORD:     ${{ secrets.PG_PASSWORD }}
```

Add the secrets at the **repo** level under Settings → Secrets and
variables → Actions:

- `DEPLOY_SSH_KEY` — same key Kamal uses
- `PG_HOST`, `PG_USER`, `PG_PASSWORD` — admin creds on the staging DB
  cluster
- `VPN_PRIVATE_KEY`, `VPN_PUBLIC_KEY` — only if you're using the
  WireGuard step

## Step 6: Open a test PR

Push any branch and open a pull request. Within a few minutes you should
see:

1. A "Preview environment is building…" comment on the PR.
2. A "View deployment" button on the PR (linked to the preview URL).
3. The comment updating to "Preview environment is ready" with the URL.

Open the URL in a browser — you should see your app, populated with the
data from `myapp_staging` cloned moments ago.

## Step 7 (recommended): Add the daily sweeper

The deploy / teardown lifecycle is event-driven and very reliable, but
GitHub Actions does occasionally miss events (outage, branch deleted while
Actions was disabled, etc.). The sweeper reconciles registered preview
environments against open PRs once a day and tears down orphans. See
[`examples/postgres/sweep.yml`](../examples/postgres/sweep.yml).

## What's next?

- [`docs/databases.md`](databases.md) — engine-specific notes, including
  how to sanitize PII before cloning and how to use the in-container
  clone alternative.
- [`docs/dns-and-tls.md`](dns-and-tls.md) — wildcard certs, DNS-01 vs.
  HTTP-01 challenges, the cookie-domain footgun.
- [`docs/secrets.md`](secrets.md) — Kamal's `kamal secrets` integration
  with 1Password, AWS Secrets Manager, Doppler, and friends.
- [`docs/resource-limits.md`](resource-limits.md) — keep preview costs
  in check via memory/CPU caps, branch filtering, and a hard cap on
  concurrent previews.
- [`docs/troubleshooting.md`](troubleshooting.md) — common failure modes
  and how to diagnose them.
- [`docs/reference.md`](reference.md) — every input, output, and secret.
