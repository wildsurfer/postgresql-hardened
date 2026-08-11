# Revive postgresql-hardened Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update the image to postgres 18, add a smoke test, and publish it to GHCR automatically via GitHub Actions.

**Architecture:** One Dockerfile (postgres:18-alpine + PGXN safeupdate preloaded), one shell smoke test used both locally and in CI, one GitHub Actions workflow that builds, tests, and pushes to `ghcr.io/wildsurfer/postgresql-hardened`.

**Tech Stack:** Docker, POSIX sh, GitHub Actions. No other tooling.

## Global Constraints

- Base image: `postgres:18-alpine` (moving tag — do not pin a minor version).
- Registry and image name: `ghcr.io/wildsurfer/postgresql-hardened`, tags `latest` and the postgres major (`18`, derived at push time, not hardcoded).
- CI pushes only on `master` pushes and the weekly cron, never on pull requests.
- No AI/Claude attribution anywhere: commits, comments, README.
- Spec: `docs/superpowers/specs/2026-08-11-revive-postgresql-hardened-design.md`.

---

### Task 1: Dockerfile update + smoke test

**Files:**
- Modify: `Dockerfile`
- Create: `smoke-test.sh` (repo root, executable)

**Interfaces:**
- Produces: `smoke-test.sh <image>` — exits 0 if the image boots and blocks `UPDATE`/`DELETE` without `WHERE`, non-zero otherwise. Task 2's workflow calls it exactly as `./smoke-test.sh postgresql-hardened`.

- [ ] **Step 1: Write the smoke test**

Create `smoke-test.sh` with this content and `chmod +x` it:

```sh
#!/bin/sh
# Verifies the image blocks UPDATE/DELETE without WHERE.
# Usage: ./smoke-test.sh <image>
set -e

IMAGE="${1:?usage: smoke-test.sh <image>}"
CID=$(docker run -d -e POSTGRES_PASSWORD=test "$IMAGE")
trap 'docker rm -f "$CID" >/dev/null' EXIT

# Wait for init to finish (the entrypoint starts a temporary server first),
# then for the real server to accept connections.
i=0
until docker logs "$CID" 2>&1 | grep -q "PostgreSQL init process complete"; do
  i=$((i+1))
  if [ "$i" -ge 60 ]; then echo "FAIL: init did not complete"; docker logs "$CID"; exit 1; fi
  sleep 1
done
i=0
until docker exec "$CID" pg_isready -U postgres >/dev/null 2>&1; do
  i=$((i+1))
  if [ "$i" -ge 30 ]; then echo "FAIL: server not ready"; docker logs "$CID"; exit 1; fi
  sleep 1
done

sql() { docker exec "$CID" psql -U postgres -v ON_ERROR_STOP=1 -c "$1"; }

sql "CREATE TABLE t (id int); INSERT INTO t VALUES (1),(2);"
sql "UPDATE t SET id = 3 WHERE id = 1;"
sql "DELETE FROM t WHERE id = 2;"

if sql "UPDATE t SET id = 4;"; then
  echo "FAIL: UPDATE without WHERE succeeded"; exit 1
fi
if sql "DELETE FROM t;"; then
  echo "FAIL: DELETE without WHERE succeeded"; exit 1
fi
echo "OK: unqualified UPDATE/DELETE are blocked"
```

- [ ] **Step 2: Run the smoke test against plain postgres to verify it fails**

This is the "test fails without the fix" check — plain postgres has no safeupdate, so the unqualified UPDATE succeeds and the script must exit non-zero.

Run: `docker pull postgres:18-alpine && ./smoke-test.sh postgres:18-alpine; echo "exit: $?"`
Expected: `FAIL: UPDATE without WHERE succeeded`, exit 1.

- [ ] **Step 3: Update the Dockerfile**

Replace the whole `Dockerfile` with:

```dockerfile
FROM postgres:18-alpine

RUN apk add --no-cache --virtual build-deps make build-base py3-pip clang19 llvm19 && \
  pip install --break-system-packages pgxnclient && \
  pgxn install safeupdate && \
  echo "shared_preload_libraries=safeupdate" >> /usr/local/share/postgresql/postgresql.conf.sample && \
  apk del build-deps
```

Changes vs the old file: base 12.1 → 18, dropped the deprecated `MAINTAINER` line, `py-pip` → `py3-pip` (Alpine 3 renamed it), added `--break-system-packages` (PEP 668 — current Alpine pip refuses to install system-wide without it), `clang`/`llvm` → `clang19`/`llvm19`.

**If the build fails at the bitcode/clang step:** the base image records which clang it was built with. Find it with:

```sh
docker run --rm postgres:18-alpine sh -c "grep -m1 -E '^CLANG' /usr/local/lib/postgresql/pgxs/src/Makefile.global"
```

and change `clang19 llvm19` to the version it names (e.g. `CLANG = clang-20` → `clang20 llvm20`).

**If `pgxn install safeupdate` fails to compile against postgres 18:** fall back to building from upstream source inside the same RUN layer, replacing the two pip/pgxn lines:

```dockerfile
RUN apk add --no-cache --virtual build-deps make build-base clang19 llvm19 && \
  wget -qO /tmp/safeupdate.tar.gz https://github.com/eradman/pg-safeupdate/archive/refs/tags/1.5.tar.gz && \
  tar -xzf /tmp/safeupdate.tar.gz -C /tmp && \
  make -C /tmp/pg-safeupdate-1.5 install && \
  rm -rf /tmp/safeupdate.tar.gz /tmp/pg-safeupdate-1.5 && \
  echo "shared_preload_libraries=safeupdate" >> /usr/local/share/postgresql/postgresql.conf.sample && \
  apk del build-deps
```

- [ ] **Step 4: Build the image**

Run: `docker build --pull -t postgresql-hardened .`
Expected: successful build. Watch the `pgxn install safeupdate` output for a compile of `safeupdate.c` with no errors.

- [ ] **Step 5: Run the smoke test against the built image to verify it passes**

Run: `./smoke-test.sh postgresql-hardened`
Expected: `OK: unqualified UPDATE/DELETE are blocked`, exit 0. The two blocked statements should show `ERROR:  UPDATE requires a WHERE clause` / `ERROR:  DELETE requires a WHERE clause` in the output.

- [ ] **Step 6: Commit**

```bash
git add Dockerfile smoke-test.sh
git commit -m "Update to postgres 18, add smoke test"
```

---

### Task 2: GitHub Actions workflow

**Files:**
- Create: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: `./smoke-test.sh <image>` from Task 1 (exit 0 = pass).
- Produces: images at `ghcr.io/wildsurfer/postgresql-hardened:{latest,<major>}`.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/build.yml`:

```yaml
name: build

on:
  push:
    branches: [master]
  pull_request:
  schedule:
    - cron: '17 4 * * 1'

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4

      - name: Build
        run: docker build --pull -t postgresql-hardened .

      - name: Smoke test
        run: ./smoke-test.sh postgresql-hardened

      - name: Push to GHCR
        if: github.event_name != 'pull_request'
        run: |
          echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u "${{ github.actor }}" --password-stdin
          MAJOR=$(docker run --rm postgresql-hardened postgres --version | grep -oE '[0-9]+' | head -1)
          docker tag postgresql-hardened "ghcr.io/wildsurfer/postgresql-hardened:latest"
          docker tag postgresql-hardened "ghcr.io/wildsurfer/postgresql-hardened:$MAJOR"
          docker push "ghcr.io/wildsurfer/postgresql-hardened:latest"
          docker push "ghcr.io/wildsurfer/postgresql-hardened:$MAJOR"
```

Notes for the implementer:
- `--pull` matters: the weekly cron only picks up new postgres minors if the base tag is re-pulled.
- Scheduled workflows run against the default branch only — that is the intent.
- No buildx/metadata-action/login-action: plain docker CLI does everything needed here.
- `postgres --version` prints e.g. `postgres (PostgreSQL) 18.1`; `grep -oE '[0-9]+' | head -1` extracts `18`.

- [ ] **Step 2: Validate the YAML parses**

Run: `ruby -ryaml -e 'YAML.load_file(".github/workflows/build.yml"); puts "yaml ok"'`
Expected: `yaml ok`. (Ruby ships with macOS; use `actionlint` instead if it is installed.)

The workflow itself can only truly run on GitHub — it will get exercised by the PR/merge of this branch. Check the Actions tab after pushing.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "Add CI: build, smoke test, publish to GHCR"
```

---

### Task 3: README

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: image name/tags from Task 2.

- [ ] **Step 1: Write the README**

Replace `README.md` with:

```markdown
# postgresql-hardened

The official `postgres:18-alpine` image with the
[safeupdate](https://github.com/eradman/pg-safeupdate) extension preloaded.
`UPDATE` and `DELETE` statements without a `WHERE` clause are rejected.

## Usage

    docker run -d -e POSTGRES_PASSWORD=secret ghcr.io/wildsurfer/postgresql-hardened

Drop-in replacement for the official image; all `postgres` image options work.

    postgres=# UPDATE accounts SET balance = 0;
    ERROR:  UPDATE requires a WHERE clause

## Tags

- `latest`, `18` — current postgres 18 minor, rebuilt weekly so upstream
  updates are picked up automatically.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "Write README"
```
