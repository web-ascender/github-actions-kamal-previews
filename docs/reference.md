# Reference

Every input, output, and secret consumed by the reusable workflow and
top-level composite actions.

## Reusable workflow inputs

`web-ascender/github-actions-kamal-previews/.github/workflows/preview.yml@v1`

### Required

| Input | Description |
| --- | --- |
| `base-deploy-file`        | Path to the base Kamal deploy file (e.g. `config/deploy.staging.yml`). |
| `domain-suffix`           | DNS suffix for preview URLs. e.g. `preview.example.com`. |
| `deploy-host`             | SSH host where the per-PR Kamal app runs. |

### Database

| Input | Description |
| --- | --- |
| `database-engine`           | One of `postgres`, `mysql`, `sqlite`, `none`. Default `none`. |
| `databases`                 | Multi-line list (postgres/mysql). One entry per line, format `ENV_NAME=source_db:target_pattern`. Pattern tokens: `{slug}`, `{db_slug}`, `{base_database}` (= source). Each entry produces a clone-on-deploy, an `env.clear[ENV_NAME]` write, a `$ENV_NAME` runner-env export, and a drop-on-teardown. |
| `database-admin-url-var`    | Variable name to read from `base-secrets-file` as the admin connection URL. Default `DATABASE_URL`. |
| `sqlite-source-path`        | Absolute path on the deploy host to the source SQLite file (engine=sqlite). |
| `sqlite-target-path-pattern`| Pattern for the per-PR SQLite path (engine=sqlite). Tokens: `{slug}`, `{db_slug}`. |
| `sqlite-also-clone`         | Space-separated suffixes for companion SQLite files (e.g. "_queue _cache _cable"). |

The action resolves an admin URL for cloning in this order:

1. The `DATABASE_ADMIN_URL` secret/env var (explicit override).
2. The variable named by `database-admin-url-var` (default `DATABASE_URL`), read from `base-secrets-file` after sourcing it. For Rails apps, this typically means the same URL `bin/rails credentials:fetch` returns at deploy time.

The role in the URL must have `CREATEDB` (postgres) / `CREATE DATABASE` (mysql) privilege. If the URL exposed by your secrets file connects as a least-privilege app role, set `DATABASE_ADMIN_URL` to a separate admin URL.

### Generation knobs

| Input | Default | Description |
| --- | --- | --- |
| `base-secrets-file`     | `""`        | Path to base Kamal secrets file. Empty = skip copy. |
| `domain-label-pattern`  | `{slug}`    | Leftmost DNS label. |
| `service-pattern`       | `{base_service}-{slug}` | Per-PR Kamal `service:` name. |
| `destination-pattern`   | `{slug}`    | Filename suffix for `config/deploy.<destination>.yml`. |
| `env-label`             | `preview`   | Written to `labels.environment` and `FEATURE_BRANCH_LABEL`. |
| `env-overrides`         | `""`        | Newline-separated KEY=VALUE pairs merged into env.clear. |
| `env-secret-overrides`  | `""`        | Newline-separated extra entries appended to env.secret. |
| `deploy-timeout`        | `""`        | Override Kamal's `deploy_timeout` (seconds). |
| `builder-context`       | `""`        | Override `builder.context` (e.g. `.` to allow uncommitted code). |
| `prefix-strip`          | `feature/,feat/,fix/,bug/,bugfix/,chore/,hotfix/,release/` | Prefixes to strip from branch names before slug generation. |
| `image-tag`             | `""`        | Override the image tag. Pass the head SHA for cache-friendly tagging. |
| `memory-limit`          | `""`        | Per-PR Docker `--memory` cap (e.g. `256m`, `1g`). Applied to every server role. See [`resource-limits.md`](resource-limits.md). |
| `cpu-limit`             | `""`        | Per-PR Docker `--cpus` cap (e.g. `0.5`). Applied to every server role. |
| `branch-pattern`        | `""`        | Bash-glob pattern; only branches matching it get previews. Empty = every PR. |
| `max-active-previews`   | `0`         | Hard cap on concurrent active previews. 0 = unlimited. |

### Runner / Kamal

| Input | Default | Description |
| --- | --- | --- |
| `ruby-version`     | `"3.3"`     | Ruby version installed by `ruby/setup-ruby`. |
| `kamal-version`    | `""`        | Specific Kamal gem version. Empty = latest. |
| `ssh-user`         | `deploy`    | SSH user for the deploy host. |
| `ssh-port`         | `"22"`      | SSH port. |

## Reusable workflow secrets

GitHub Actions repository secrets must be `UPPERCASE_WITH_UNDERSCORES`,
so the reusable workflow declares its expected secrets in that style.
With `secrets: inherit`, repo-level secrets matching these names are
forwarded automatically.

| Secret | Required | Description |
| --- | --- | --- |
| `SSH_PRIVATE_KEY`     | Yes | Private key for SSHing into the deploy host. |
| `RAILS_MASTER_KEY`    | When `base-secrets-file` shells out to `bin/rails credentials:fetch` to populate `DATABASE_URL` — the runner needs the master key to decrypt staging credentials. |
| `DATABASE_ADMIN_URL`  | Optional | Explicit admin URL for cloning, overriding the URL read from `base-secrets-file`. Use when your app role lacks `CREATEDB`. |
| `KAMAL_REGISTRY_USERNAME` | No  | Pre-login registry username. Same env var Kamal itself reads during `deploy.yml` ERB interpolation, so one secret can serve both. Most setups don't need a pre-login when registry auth is configured in `deploy.yml`. |
| `KAMAL_REGISTRY_PASSWORD` | No  | Password matching `KAMAL_REGISTRY_USERNAME`. |

`secrets: inherit` from your calling workflow makes all of the above
auto-pass through.

## Sweep workflow inputs

`web-ascender/github-actions-kamal-previews/.github/workflows/sweep.yml@v1`

Same shape as the preview workflow, plus:

| Input | Default | Description |
| --- | --- | --- |
| `environment-prefix` | `preview-` | Only environments starting with this string are considered. |
| `dry-run`            | `false`    | When `true`, log orphans without acting. |

## Outputs

The reusable workflow's `deploy` job exposes these outputs (consumable
via `needs.preview.outputs.*` if you wrap it):

| Output | Description |
| --- | --- |
| `slug`           | DNS-safe slug derived from the branch. |
| `db_slug`        | SQL-identifier-safe slug. |
| `destination`    | Kamal destination identifier. |
| `proxy_host`     | Final hostname assigned to the preview app. |
| `database_name`  | Resolved database name (empty when `database-engine=none`). |
| `url`            | Full `https://` URL of the preview app. |

## Environment variables injected into the per-PR Kamal app

kamal-previews writes these to `env.clear` of every generated
`config/deploy.<destination>.yml`. Your application code can read them.

| Var | Value | Notes |
| --- | --- | --- |
| `FEATURE_BRANCH`         | `"true"` | Use this to gate preview-only behaviour in your app. |
| `FEATURE_BRANCH_LABEL`   | Value of the `env-label` input. | Default `preview`. |
| `FEATURE_BRANCH_SLUG`    | The branch slug. | DNS-safe. |
| `FEATURE_BRANCH_DB_SLUG` | The DB slug. | SQL-identifier-safe. |
| (Each `databases:` entry's `ENV_NAME`) | Resolved per-PR DB name. | One entry per `databases` line. |

Plus anything you pass via `env-overrides:`.

## Runner env vars exported by `generate-config`

Every `databases:` entry's `ENV_NAME` is also written to the GitHub
Actions runner env (`$GITHUB_ENV`). That makes it visible to subsequent
steps in the same job — most importantly, kamal's own secrets-file
evaluation (which runs on the runner shell *before* the per-PR
deploy.yml is rendered, so it can't read `env.clear`).

This is what lets your `.kamal/secrets.<dest>` file build per-PR URLs
like:

```bash
DATABASE_URL=$(bin/rails credentials:fetch --environment staging database_url \
              | sed -E "s|/[^/?]+(\\?|$)|/$DATABASE_NAME\\1|")
```

See [`docs/secrets.md`](secrets.md) for the full pattern.

## CLI: `bin/kamal-previews`

```
kamal-previews generate    --branch <name> --base-deploy-file <path> --domain-suffix <suffix> [options]
kamal-previews slugify     --branch <name>
kamal-previews version
kamal-previews help
```

Run any subcommand with `--help` for full options.
