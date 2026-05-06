# Examples

Drop-in workflow files for each supported database engine. Copy the relevant
file into your Rails app at `.github/workflows/preview.yml` (and
`.github/workflows/preview-sweep.yml` for the optional sweeper) and adjust
the `with:` and `secrets:` blocks for your environment.

| File | Use when |
| --- | --- |
| [postgres/preview.yml](postgres/preview.yml)   | Your staging DB is PostgreSQL. |
| [postgres/sweep.yml](postgres/sweep.yml)       | Optional daily orphan cleanup. |
| [mysql/preview.yml](mysql/preview.yml)         | Your staging DB is MySQL. |
| [sqlite/preview.yml](sqlite/preview.yml)       | Your staging DB is SQLite (file on the deploy host). |
