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

## Per-PR DB names in your secrets file

Each entry in `databases:` (e.g. `DATABASE_NAME=myapp_staging:myapp_{db_slug}`)
gives the deployed container its per-PR DB name in `env.clear`. But your
`.kamal/secrets.<dest>` file usually needs to *build a URL* from that
name, not just read it. The same names are exported to the GitHub Actions
runner env, so the secrets file can read them when Kamal evaluates it.

The four common patterns:

### 1. Rewrite the URL fetched from Rails credentials

```bash
# .kamal/secrets.preview
RAILS_MASTER_KEY=$RAILS_MASTER_KEY

# Pull the staging URL, swap in the per-PR DB name. $DATABASE_NAME comes
# from kamal-previews via the runner env.
_BASE=$(bin/rails credentials:fetch --environment staging database_url)
DATABASE_URL=$(echo "$_BASE" | sed -E "s|/[^/?]+(\\?|$)|/$DATABASE_NAME\\1|")
QUEUE_DATABASE_URL=$(echo "$_BASE" | sed -E "s|/[^/?]+(\\?|$)|/$QUEUE_DATABASE_NAME\\1|")
CACHE_DATABASE_URL=$(echo "$_BASE" | sed -E "s|/[^/?]+(\\?|$)|/$CACHE_DATABASE_NAME\\1|")
```

### 2. Build URLs from individual env-var components

If you store host/user/password as separate values:

```bash
# .kamal/secrets.preview
DATABASE_URL=postgres://${PG_USER}:${PG_PASSWORD}@${PG_HOST}/${DATABASE_NAME}?sslmode=verify-full
```

### 3. App reads `DATABASE_NAME` directly

If your `database.yml` for the staging environment uses
`<%= ENV["DATABASE_NAME"] %>` or similar, you don't need a special
secrets file at all — the env var lands in `env.clear` and the app
reads it.

### 4. Look up secrets keyed by per-PR DB name

For 1Password / Doppler / AWS Secrets Manager, you can use
`$DATABASE_NAME` in the lookup key:

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
