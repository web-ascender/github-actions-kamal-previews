# Bounding preview-environment cost

Previews accumulate. Without bounds, ten open PRs on a busy repo means ten
Kamal apps quietly sitting on your staging host eating RAM. This page
covers the three knobs feature-deploys exposes for keeping that under
control, plus the path forward when upstream Kamal ships scale-to-zero.

## TL;DR

| Goal | Knob | Default |
| --- | --- | --- |
| Don't deploy previews for *every* branch | `branch-pattern` (workflow input) | empty (all PRs) |
| Cap RAM / CPU per preview | `memory-limit`, `cpu-limit` (workflow inputs) | empty (no cap) |
| Cap number of *concurrent* previews | `max-active-previews` (workflow input) | 0 (unlimited) |

Combine all three for a tight setup.

## 1. `branch-pattern` — be selective about which branches deploy

Default: every PR opened against the repo gets a preview. That's the
modern review-app norm (Heroku, Render, Vercel). But sometimes you want
to limit to a naming convention — for example, the seed implementation
in `kamal-previews` only triggered on `feature/*` branches.

```yaml
jobs:
  preview:
    uses: web-ascender/feature-deploys/.github/workflows/preview.yml@v1
    with:
      branch-pattern: "feature/**"     # bash glob (extglob enabled)
      ...
```

The pattern is evaluated by bash with `extglob` on, so:

| Pattern | Matches |
| --- | --- |
| `"feature/**"`            | `feature/foo`, `feature/sub/bar` |
| `"@(feature|fix)/*"`      | `feature/x`, `fix/y` |
| `"release-+([0-9.])"`     | `release-1.2.3` |
| `"!(*staging*)"`          | every branch except those containing "staging" |

Branches that *don't* match are simply skipped — the workflow run shows
a `notice` annotation and exits with a non-failure.

**Important:** the pattern only filters *new deploys*. Teardowns always
run, so changing the pattern after the fact won't orphan existing
previews — the close / delete event still tears them down.

## 2. `memory-limit` and `cpu-limit` — cap each preview's resource use

Kamal exposes raw `docker run` flags via `servers.<role>.options`.
feature-deploys takes two of those — `--memory` and `--cpus` — and
applies them across every server role in the per-PR generated config:

```yaml
with:
  memory-limit: "256m"   # passes --memory 256m to every preview container
  cpu-limit:    "0.5"    # passes --cpus 0.5
```

Reasonable starting points:

| App size | `memory-limit` | `cpu-limit` |
| --- | --- | --- |
| Small Rails app, single role | 256m – 512m | 0.25 – 0.5 |
| Multi-role (web + job)       | 512m web + 256m job | 0.5 + 0.25 |
| Bigger app                   | 1g | 1 |

These caps apply to the *per-PR* preview only — your staging
deploy.yml is untouched. Hitting the memory cap triggers Linux OOM and
the container restarts (Kamal will keep restarting it). If your preview
is OOMing on what should be a fine cap, the issue is usually a stuck
asset compile or a memory-hungry boot path — investigate, don't just
raise the cap.

## 3. `max-active-previews` — hard cap on concurrent previews

The deploy job, before generating a deployment, queries the GitHub
Deployments API for environments named `preview-*` whose latest status
is *active* (not `inactive`, `removed`, `failure`, or `error`). If
that count is already at the cap, the deploy fails fast with a friendly
PR comment explaining why.

```yaml
with:
  max-active-previews: 5     # at most 5 active previews at any moment
```

The cap is **inclusive**: 5 means "five running, refuse the sixth." A
re-deploy of a preview that's *already* counted doesn't trip the cap —
you can keep pushing to existing PRs even when at the limit.

The PR comment uses the same `<!-- feature-deploys:status -->` marker
as the regular status comment, so it occupies that slot until the next
successful deploy replaces it.

**Recovery from the cap:** close another preview's PR, or wait for the
sweeper to reap an orphan. The capped run can then be re-triggered from
the Actions tab.

## What about scale-to-zero?

Today, **Kamal and `kamal-proxy` do not support scale-to-zero**. There
is no built-in idle-shutdown, no on-demand-start activator, no
`kamal app sleep`. The closest thing is `kamal app stop` (manual) and
`kamal app maintenance` (serves a static page from the proxy, doesn't
actually stop the container).

The upstream tracking item is
**[basecamp/kamal-proxy#197](https://github.com/basecamp/kamal-proxy/pull/197)**,
a draft PR by martijnenco titled *"Add idle container support
(scale-to-zero)"*. It proposes exactly what we'd want:

> Containers are stopped after a configurable period of inactivity and
> transparently restarted when new requests arrive.

Status as of this writing: still draft, Copilot has left ~10 review
comments, no public maintainer review yet. When (if) it ships, this
project will gain a thin wrapper that exposes the new flags — likely as
two new `idle-timeout` / `idle-wake-timeout` workflow inputs.

Until then, the three knobs above are the practical answer. A typical
production setup looks like:

```yaml
with:
  branch-pattern:      "feature/**"
  memory-limit:        "512m"
  cpu-limit:           "0.5"
  max-active-previews: 8
```

## Roll-your-own auto-suspend (advanced)

If you really need scale-to-zero before #197 lands, the cleanest DIY
path is a separate workflow scheduled hourly that:

1. Lists active preview environments via the Deployments API.
2. For each, checks the most recent activity (`kamal app details
   -d <slug>` exposes container start time, but not request count —
   you'd need to scrape `kamal-proxy` access logs from the host).
3. For previews idle longer than N hours, runs `kamal app stop -d <slug>`.
4. On the next push to that branch, the regular deploy workflow runs
   `kamal app start -d <slug>` (or just re-deploys, which boots the
   container).

This isn't shipped. If you build it, please contribute back.
