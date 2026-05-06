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
| `database-template`         | Source database to clone from (postgres/mysql). |
| `database-name-pattern`     | Pattern for the per-PR DB name. Tokens: `{slug}`, `{db_slug}`, `{base_database}`. Required for postgres/mysql. |
| `sqlite-source-path`        | Absolute path on the deploy host to the source SQLite file (engine=sqlite). |
| `sqlite-target-path-pattern`| Pattern for the per-PR SQLite path (engine=sqlite). Tokens: `{slug}`, `{db_slug}`. |
| `sqlite-also-clone`         | Space-separated suffixes for companion SQLite files (e.g. "_queue _cache _cable"). |

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
| `PG_HOST`             | (postgres) | PostgreSQL server hostname. |
| `PG_USER`             | (postgres) | PostgreSQL admin user (must have CREATEDB). |
| `PG_PASSWORD`         | (postgres) | Password for `PG_USER`. |
| `PG_PORT`             | No  | Default `5432`. |
| `PG_SSLMODE`          | No  | `require`, `prefer`, `disable`, etc. |
| `MYSQL_HOST`          | (mysql) | MySQL server hostname. |
| `MYSQL_USER`          | (mysql) | MySQL admin user. |
| `MYSQL_PASSWORD`      | (mysql) | Password for `MYSQL_USER`. |
| `MYSQL_PORT`          | No  | Default `3306`. |
| `MYSQL_SSL_MODE`      | No  | `REQUIRED`, `DISABLED`, etc. |
| `REGISTRY_USERNAME`   | No  | Pre-login registry username. Most setups don't need this — Kamal handles registry auth itself when configured in `deploy.yml`. |
| `REGISTRY_PASSWORD`   | No  | Password matching `REGISTRY_USERNAME`. |

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

feature-deploys writes these to `env.clear` of every generated
`config/deploy.<destination>.yml`. Your application code can read them.

| Var | Value | Notes |
| --- | --- | --- |
| `FEATURE_BRANCH`         | `"true"` | Use this to gate preview-only behaviour in your app. |
| `FEATURE_BRANCH_LABEL`   | Value of the `env-label` input. | Default `preview`. |
| `FEATURE_BRANCH_SLUG`    | The branch slug. | DNS-safe. |
| `FEATURE_BRANCH_DB_SLUG` | The DB slug. | SQL-identifier-safe. |
| `DATABASE_NAME`          | Result of `database-name-pattern`. | Only set when `database-name-pattern` is provided. |

Plus anything you pass via `env-overrides:`.

## CLI: `bin/feature-deploys`

```
feature-deploys generate    --branch <name> --base-deploy-file <path> --domain-suffix <suffix> [options]
feature-deploys slugify     --branch <name>
feature-deploys version
feature-deploys help
```

Run any subcommand with `--help` for full options.
