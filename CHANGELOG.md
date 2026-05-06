# Changelog

All notable changes to kamal-previews are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Initial extraction from `kamal-previews`.
- Reusable GitHub workflow (`.github/workflows/preview.yml`) covering the full
  preview-environment lifecycle: deploy on PR open/sync, teardown on PR close
  and on branch delete.
- Composite actions: `setup`, `generate-config`, `clone-database`,
  `drop-database`, `deploy`, `teardown`, `pr-comment`.
- Stdlib-only Ruby library (`lib/kamal_previews/`) for branch-name
  sanitization and per-PR Kamal config generation.
- Database adapters for PostgreSQL, MySQL, and SQLite (Docker-based, no client
  tools required on the deploy host).
- Sweeper workflow (`.github/workflows/preview-sweep.yml`) that reconciles
  active deploys against open PRs nightly.
- Native GitHub Deployments API integration so PRs get a "View deployment"
  button.
- Single rolling PR comment with status, URL, logs, and a teardown button.
- Examples for each supported database engine.
- Minitest suite covering the namer, the config generator, and CLI argument
  parsing.

### Changed compared to the kamal-previews seed
- Switched from `push: feature/*` triggers to `pull_request` + `delete` —
  better lifecycle, no need to enforce a branch-naming convention.
- Switched from in-container database clone (entrypoint hook) to host-side
  clone over SSH by default. In-container mode remains available for setups
  where the runner can't reach the deploy host's network.
- Per-PR Kamal config no longer hard-codes builder context to `.` — uses the
  committed ref by default.
- Configurable everything: domain suffix, database name pattern, env tag
  label, image tag, base deploy/secrets file paths.
