# Examples

Drop-in workflow files for each supported database engine. Copy the
relevant file into your Rails app at `.github/workflows/preview.yml` (and
`.github/workflows/preview-sweep.yml` for the optional sweeper) and
adjust the `with:`, `env:`, and `secrets:` blocks for your environment.

| File | Use when |
| --- | --- |
| [minimal/preview.yml](minimal/preview.yml)     | Public deploy host, single Postgres DB. The shortest config that works. |
| [postgres/preview.yml](postgres/preview.yml)   | Your staging DB is PostgreSQL — full-featured (VPN pairing, multi-DB, caps). |
| [postgres/sweep.yml](postgres/sweep.yml)       | Optional daily orphan cleanup. |
| [mysql/preview.yml](mysql/preview.yml)         | Your staging DB is MySQL. |
| [sqlite/preview.yml](sqlite/preview.yml)       | Your staging DB is SQLite (file on the deploy host). |

Every example uses the **composite action** form (`uses:
web-ascender/github-actions-kamal-previews@v1`) — a single step inside a single job.
This composes naturally with a sibling VPN step. See the
[postgres example](postgres/preview.yml) for a worked VPN pairing.

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

The reusable workflow form does NOT support VPN pairing (workflows
are jobs, not steps — there's no place to insert a sibling VPN step). If
your deploy host is private, use the composite action form.
