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
