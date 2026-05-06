# Troubleshooting

## Kamal pre-build / pre-deploy hooks reject preview deployments

If your repo has a `.kamal/hooks/pre-build` or `pre-deploy` script that
gates on the branch-vs-destination combination (e.g. only `master` →
`production` and `rails8` → `staging`), it will reject every preview
because preview destinations don't appear in that allowlist.

Two clean fixes — pick whichever you prefer:

**1. Detect previews by destination prefix.** Set
`destination-pattern: preview-{slug}` on the action, then teach the
hook to bypass its branch check for any preview destination:

```ruby
# .kamal/hooks/pre-build
exit(true) if ENV["KAMAL_DESTINATION"]&.start_with?("preview-")
# …existing branch / destination assertions below…
```

**2. Detect previews by `FEATURE_BRANCH=true` env var.** kamal-previews
sets this in `env.clear` of every per-PR config. Useful in `pre-deploy`
hooks where the env is already loaded.

The action exposes `KAMAL_DESTINATION` to hooks like every Kamal
deploy does, so option (1) requires no extra plumbing.

## "host is used by another service" (kamal-proxy)

`kamal-proxy` enforces uniqueness on `proxy.host:` across all apps on a
host. If you see this on first deploy, the most common cause is your
`base-deploy-file` declaring `proxy.host: staging.example.com` while the
existing staging app already owns that hostname.

This shouldn't happen in normal operation: kamal-previews overrides
`proxy.host` in every per-PR file. But if `domain-label-pattern` resolves
to the same hostname twice (e.g., the staging label collides with a slug),
you'll see this error.

Run `bin/kamal-previews slugify --branch <name>` to preview the slug for
a branch and confirm there's no overlap.

## "FATAL: source database is being accessed by other users"

PostgreSQL's `CREATE DATABASE … TEMPLATE` requires no active connections
to the source database. The `clone.sh` script calls `pg_terminate_backend`
to evict connections and waits up to `DISCONNECT_TIMEOUT` (default 15s)
for them to actually drop, but a connection pool that auto-reconnects can
defeat this.

Mitigations, in order of preference:

1. **Use a dedicated template database** that nothing else connects to,
   refreshed from staging on a schedule. Point each `databases:` entry's
   source at the template, not at staging.

2. **Lower the connection-reaping aggressiveness** of your staging app.
   Idle-in-transaction timeouts and connection lifetimes help.

3. **Increase `DISCONNECT_TIMEOUT`** by patching the script (planned as a
   first-class input in v0.2).

## "kamal-proxy: failed to obtain TLS certificate"

`kamal-proxy` couldn't complete the Let's Encrypt HTTP-01 challenge.
Common causes:

- DNS wildcard isn't in place yet (or hasn't propagated). Check with
  `dig <slug>.preview.example.com`.
- Port 80 isn't open to the public internet. Required for HTTP-01.
- You hit Let's Encrypt rate limits (50 certs/registered-domain/week).
  Switch to wildcard TLS — see [`dns-and-tls.md`](dns-and-tls.md).

## "permission denied (publickey)" during clone-database

The `ssh-private-key` secret isn't being loaded into ssh-agent, or the
key isn't authorized on the deploy host.

Check:

```bash
# In a workflow run with debug logging enabled (set ACTIONS_STEP_DEBUG=true):
ssh-add -l   # should list the key fingerprint
ssh -v deploy@<your host>   # should authenticate via 'publickey'
```

Common gotcha: GitHub Secrets strip trailing newlines from values. If your
key was copy-pasted without a final newline, ssh-agent rejects it. Re-paste
making sure there's a newline after `-----END OPENSSH PRIVATE KEY-----`.

## "remote: Permission to <repo>.git denied to github-actions[bot]"

The PR-comment step or deployment-status step is being blocked by repo
policy. Check that the calling workflow has:

```yaml
permissions:
  contents: read
  pull-requests: write
  deployments: write
```

If you're calling the reusable workflow from a fork-originated PR, GitHub
restricts the `secrets:` and `permissions:` available — that's a GitHub
security feature, not a kamal-previews bug.

## The PR comment is duplicated, not updated

The `pr-comment` action identifies its previous comment by an HTML
marker (`<!-- kamal-previews:status -->`). If the comment was edited by
hand and the marker stripped, the action will create a new one on the
next run. Either restore the marker or accept the duplicate.

## Slug is empty / "branch name produces empty slug"

The Namer rejects sanitized slugs that are empty after stripping
non-alphanumeric characters. Branches like `---` or `///` will fail.
Realistic branches won't trip this — but feel free to file an issue if
you find one that does.

## Preview environment is "ready" but my app's data is empty

Most common cause: your per-PR app isn't reading the `DATABASE_NAME` env
var. Check `config/database.yml`:

```yaml
staging:
  primary:
    database: <%= ENV.fetch("DATABASE_NAME") { "myapp_staging" } %>
```

Without that fallback pattern, your app keeps connecting to
`myapp_staging` directly and ignores the freshly cloned per-PR database.

## kamal app remove fails: "no such container"

The `teardown` action tolerates this with `ignore-missing-app: true` (the
default). If you've turned that off, you'll see the error on PRs that
were closed before they ever deployed (i.e., on opened+closed in quick
succession). Leave the default.

## Sweeper tears down a deploy I want to keep

The sweeper considers an environment orphaned when no open PR matches its
slug. False positives can happen if:

- A branch was renamed after the deploy (the slug no longer matches an
  open PR).
- You're using a `destination-pattern` that doesn't match the default
  `{slug}` and the sweeper's reverse-lookup heuristic gets confused.

Run the sweeper with `dry-run: true` to see what it *would* tear down
before letting it run. If you have non-default patterns, the sweeper may
need tuning — file an issue with your pattern and we'll add a knob.

## Where to file bugs

Open an issue at https://github.com/web-ascender/github-actions-kamal-previews/issues
with:

- The minimal example workflow file you're using (with secrets stripped).
- A link to a failing run (or copy of the relevant log lines).
- The output of `kamal version` and `bin/kamal-previews version`.
