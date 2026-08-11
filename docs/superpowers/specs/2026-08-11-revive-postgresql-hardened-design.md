# Revive postgresql-hardened

Date: 2026-08-11

## What this project is

A Docker image: official `postgres` Alpine image with the PGXN `safeupdate`
extension installed and preloaded. `safeupdate` makes `UPDATE` and `DELETE`
without a `WHERE` clause fail. The repo has been untouched since Feb 2020 and
is pinned to postgres 12.1 (EOL since November 2024).

## Goal

The image builds again on a current postgres, is published automatically, and
stays current without manual work.

## Design

### Dockerfile

- Base: `postgres:18-alpine` (moving tag, tracks minor releases of the
  current major).
- Install `safeupdate` via `pgxnclient` in a single layer, same as today,
  updated for current Alpine: `py3-pip` instead of `py-pip`, and
  `pip install --break-system-packages` (PEP 668).
- Append `shared_preload_libraries=safeupdate` to
  `postgresql.conf.sample`, same as today.

### CI (GitHub Actions, `.github/workflows/build.yml`)

- Triggers: push to `master`, pull requests, weekly cron. The cron rebuild
  picks up postgres minor/security updates because the base tag moves.
- Steps: build the image, smoke test it, push to
  `ghcr.io/wildsurfer/postgresql-hardened` (push only on master and cron, not on
  PRs). Auth via the built-in `GITHUB_TOKEN`.
- Tags: `latest` and the postgres major (`18`).
- Smoke test: start the container, wait for readiness, then assert that
  `UPDATE` without `WHERE` fails and `UPDATE` with `WHERE` succeeds. This is
  the image's entire purpose, so it is the one check that matters.

### README

A few lines: what the image is, pull command, one usage example showing the
blocked `UPDATE`.

## Out of scope

- Older postgres majors (no evidence anyone needs them). A new major is a
  one-line bump once a year.
- Docker Hub publishing.
- Dependabot/Renovate — redundant with the moving base tag plus weekly cron.
- Additional hardening beyond safeupdate.

## Risks

- `safeupdate` (last PGXN release is old) may fail to compile against
  postgres 18. The CI smoke test catches this; fallback is building from the
  GitHub source (`sysadminmike/pg-safeupdate` fork or upstream) instead of
  PGXN.
