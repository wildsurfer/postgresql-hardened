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
