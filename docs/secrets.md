# Secrets

kamal-previews keeps the secret surface area as small as it can. The only
secrets the GitHub Actions workflow itself needs are:

- `SSH_PRIVATE_KEY` — registered with the deploy host. Used both for
  Kamal's SSH connection and for kamal-previews' database scripts that
  ssh to the host to run clone/drop operations.
- An admin database URL — only for postgres / mysql. By default the
  action sources your `base-secrets-file` and reads `DATABASE_URL`,
  meaning *no extra secret* is needed if your staging app role has
  `CREATEDB`. Override with `DATABASE_ADMIN_URL` only when you need a
  different role.
- `RAILS_MASTER_KEY` — only when your `base-secrets-file` shells out to
  `bin/rails credentials:fetch` (Rails encrypted credentials). The
  runner needs the master key to evaluate that file headlessly.

Everything else flows through Kamal's own `kamal secrets` mechanism,
which is fully under your control.

## Per-PR database connection — two modes

Each entry in `databases:` is named after the env var the per-PR app
should see. The action picks behavior based on the suffix:

### `*_URL` entries — automatic URL rewriting (recommended)

```yaml
databases: |
  DATABASE_URL=myapp_staging:myapp_{db_slug}
  QUEUE_DATABASE_URL=myapp_staging_queue:myapp_queue_{db_slug}
```

For each entry, the action:

1. Clones source DB → per-PR target DB
2. Sources `base-secrets-file` to read the original URL (e.g. `$DATABASE_URL`)
3. Rewrites the URL's database-name path segment to the per-PR target —
   scheme, userinfo, host, port, query string are preserved byte-for-byte
4. Injects the rewritten URL via `env.secret` at deploy time, by appending
   an override line to the generated `.kamal/secrets.<dest>` file

**Your `database.yml`, Rails credentials, and existing
`.kamal/secrets.staging` stay unchanged.** The container sees
`DATABASE_URL=postgresql://user:pass@host:5432/myapp_<slug>?sslmode=...`
— a fully-formed URL pointing at the per-PR clone, with the same
credentials your staging app uses.

### `*_NAME` (or any non-`_URL`) entries — name-only injection

```yaml
databases: |
  DATABASE_NAME=myapp_staging:myapp_{db_slug}
```

The resolved per-PR DB name (e.g. `myapp_<slug>`) is written to
`env.clear[DATABASE_NAME]` AND exported to `$GITHUB_ENV`. Use this when
your app reads `ENV["DATABASE_NAME"]` directly in `database.yml`, or when
you want to build URLs yourself in your secrets file. Examples:

**`database.yml` reads the name directly** — no secrets-file changes:
```yaml
staging:
  primary:
    database: <%= ENV["DATABASE_NAME"] %>
    # …host/user/password from URL or other env
```

**Build URLs in your secrets file** — `$DATABASE_NAME` lives in the runner env:
```bash
DATABASE_URL=postgres://${PG_USER}:${PG_PASSWORD}@${PG_HOST}/${DATABASE_NAME}?sslmode=require
```

**Look up secrets keyed by per-PR DB name** (1Password / Doppler / etc.):
```bash
SECRETS=$(kamal secrets fetch --adapter doppler myapp "preview-${DATABASE_NAME}")
DATABASE_URL=$(kamal secrets extract DATABASE_URL "$SECRETS")
```

## Two layers of secrets

It helps to separate "secrets the workflow needs" from "secrets the
deployed app needs":

| Layer | What | Where to put it |
| --- | --- | --- |
| Workflow | SSH key, DB admin creds | GitHub Actions repository secrets |
| Application | RAILS_MASTER_KEY, API keys, DB user creds the *app* uses to connect | Kamal secrets (sourced by your `.kamal/secrets.staging` file) |

The workflow's SSH key is the only thing that *has* to live in GitHub
Actions secrets. The application secrets can live anywhere Kamal can fetch
them from — 1Password, AWS Secrets Manager, GCP Secret Manager, Doppler,
Bitwarden, Passbolt, or just a plaintext `.kamal/secrets.staging` file
(don't do that).

## Application secrets via 1Password

This is what the seed Rails app — the seed implementation —
uses. Write your `.kamal/secrets.staging` like:

```bash
# .kamal/secrets.staging
SECRETS=$(kamal secrets fetch \
  --adapter 1password \
  --account yourorg.1password.com \
  --from "VAULT_ID/ITEM_ID" \
  KAMAL_REGISTRY_USERNAME \
  KAMAL_REGISTRY_PASSWORD \
  RAILS_MASTER_KEY \
  DB_PASSWORD \
)
KAMAL_REGISTRY_USERNAME=$(kamal secrets extract KAMAL_REGISTRY_USERNAME "$SECRETS")
KAMAL_REGISTRY_PASSWORD=$(kamal secrets extract KAMAL_REGISTRY_PASSWORD "$SECRETS")
RAILS_MASTER_KEY=$(kamal secrets extract RAILS_MASTER_KEY "$SECRETS")
DB_PASSWORD=$(kamal secrets extract DB_PASSWORD "$SECRETS")
```

The 1Password CLI needs to be authenticated. In CI, the cleanest path is a
service account token:

```yaml
# In your repo's .github/workflows/preview.yml, add an env var that
# kamal-previews' workflow inherits. Workflows called via `uses:` see env
# vars set on the calling workflow.
jobs:
  preview:
    uses: web-ascender/github-actions-kamal-previews/.github/workflows/preview.yml@v1
    with:
      base-secrets-file: .kamal/secrets.staging
      ...
    secrets:
      SSH_PRIVATE_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
```

Then add a small calling workflow that wraps the call to install the
1Password CLI before the reusable workflow runs:

```yaml
# Or, simpler, change `.kamal/secrets.staging` to use the OP_SERVICE_ACCOUNT_TOKEN
# directly with `op` CLI calls; install the CLI as part of your Dockerfile.
```

## Application secrets via AWS Secrets Manager

```bash
# .kamal/secrets.staging
SECRETS=$(kamal secrets fetch --adapter aws_secrets_manager \
  --region us-east-1 \
  myapp/staging/web)
RAILS_MASTER_KEY=$(kamal secrets extract RAILS_MASTER_KEY "$SECRETS")
# …
```

The runner needs AWS credentials. Use OIDC (`id-token: write` in
permissions, plus an `aws-actions/configure-aws-credentials@v4` step in
your calling workflow) so you don't have to store long-lived AWS keys.

## Application secrets via Doppler

```bash
# .kamal/secrets.staging
SECRETS=$(kamal secrets fetch --adapter doppler myapp staging)
RAILS_MASTER_KEY=$(kamal secrets extract RAILS_MASTER_KEY "$SECRETS")
```

`DOPPLER_TOKEN` is read from the runner environment.

## Per-PR secret rotation

The default behavior is to use the **same secrets bag as staging** for
every preview environment. That's almost always what you want — preview
apps talk to the same external services as staging.

If you want truly per-PR secrets (e.g., a separate `SECRET_KEY_BASE` so
session cookies don't carry across previews):

1. Set `env-secret-overrides` in the workflow inputs to add new entries
   to `env.secret`.
2. Reference those entries from your `.kamal/secrets.staging` file with
   the `KAMAL_DESTINATION` env var, which Kamal sets automatically:

   ```bash
   PREVIEW_SECRET_KEY_BASE=$(kamal secrets fetch --adapter ... \
     "myapp/preview/${KAMAL_DESTINATION}/SECRET_KEY_BASE")
   ```

3. Provision the per-PR entries up front, or generate them deterministically
   from a master seed: `SHA256(seed + slug)`.

A built-in "deterministic per-PR secret derivation" feature is on the
roadmap.

## Threat model: what can a preview app do?

Worth a moment of thought:

- **Preview apps share the same database cluster as staging.** A preview
  with a broken migration could in theory damage shared resources (e.g.
  drop a table from the public schema). The default `CREATE DATABASE
  TEMPLATE` flow gives each preview its own isolated database, so this
  is unlikely in practice — but if you let preview apps connect with
  cluster-superuser credentials, you've granted them more authority than
  they need. Use a dedicated per-app role with permissions only on its
  own database.

- **Preview apps share the same secrets as staging.** They can call any
  third-party service staging can. If your staging API keys grant access
  to production-shaped data, that's the leakage surface. Mitigate by
  using sandbox API credentials in staging-equivalent secrets bags.

- **Preview URLs are public DNS.** Anyone who can guess the slug can
  visit. The cookie-domain footgun aside (see
  [`docs/dns-and-tls.md`](dns-and-tls.md)), put HTTP basic auth or an SSO
  gate in front of preview environments if your staging data is sensitive.
