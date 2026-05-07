# Examples

Drop-in workflow files for each supported database engine. Copy the
relevant file into your Rails app at `.github/workflows/preview.yml` (and
`.github/workflows/preview-sweep.yml` for the optional sweeper) and
adjust the `with:`, `env:`, and `secrets:` blocks for your environment.

| File | Use when |
| --- | --- |
| [minimal/preview.yml](minimal/preview.yml)     | Single Postgres DB, public deploy host. The shortest config that works. |
| [postgres/preview.yml](postgres/preview.yml)   | Your staging DB is PostgreSQL — full-featured (multi-DB, resource caps, branch filters). |
| [postgres/sweep.yml](postgres/sweep.yml)       | Optional daily orphan cleanup. |
| [mysql/preview.yml](mysql/preview.yml)         | Your staging DB is MySQL. |
| [sqlite/preview.yml](sqlite/preview.yml)       | Your staging DB is SQLite (file on the deploy host). |

Every example uses the **composite action** form (`uses:
web-ascender/github-actions-kamal-previews@v1`) — a single step inside a single job.
This composes naturally with sibling steps such as a VPN tunnel for
private deploy hosts.

## Reusable-workflow form (advanced)

If you need job-level features that composite actions can't express —
matrix-fanned parallel orphan cleanup, separate runners for deploy and
teardown, GitHub's job-level concurrency UI — call the reusable
workflows instead:

```yaml
jobs:
  preview:
    uses: web-ascender/github-actions-kamal-previews/.github/workflows/preview.yml@v1
    with: { base-deploy-file: ..., domain-suffix: ..., deploy-host: ..., ... }
    secrets: inherit
```

The reusable workflow form is jobs-only — there's no place to insert
sibling steps. If you need to pair kamal-previews with another step
(e.g. a VPN tunnel for a private deploy host), use the composite
action form.
