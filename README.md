# pgbouncer

PgBouncer image for Railway's composable PgBouncer template, forked from
[edoburu/docker-pgbouncer](https://github.com/edoburu/docker-pgbouncer) (MIT).
PgBouncer itself is compiled from the official source release at
[pgbouncer.github.io](https://pgbouncer.github.io/).

Published as `ghcr.io/railwayapp-templates/pgbouncer` with tags
`<full version>`, `<major.minor>`, `<major>`, and `latest`. Rebuilt weekly on a
fresh alpine base.

## Railway-specific defaults

Three defaults differ from the upstream image:

| Setting | Upstream | Here | Why |
|---|---|---|---|
| `LISTEN_ADDR` | `0.0.0.0` | `*` | Railway's private network is IPv6; `0.0.0.0` only binds IPv4 |
| `AUTH_TYPE` | `md5` | `scram-sha-256` | Railway Postgres uses SCRAM password encryption |
| `CLIENT_TLS_SSLMODE` | `disable` | `allow` | Plaintext clients still work; a client that requests TLS gets it against a freshly generated self-signed cert instead of a hard refusal |

The self-signed cert (`/etc/pgbouncer/tls/{server.crt,server.key}`) is
generated on every boot — this image has no persistent volume, and a
self-signed cert doesn't authenticate server identity either way, so
regenerating it each start is fine for opportunistic encryption. Set
`CLIENT_TLS_SSLMODE` yourself (e.g. `disable`, or `require`/`verify-full`
alongside your own `CLIENT_TLS_CERT_FILE`/`CLIENT_TLS_KEY_FILE`) to opt out
of the generated cert or tighten the requirement.

Everything else matches upstream: configuration is generated from environment
variables on first start (`UPSTREAM_POSTGRESQL_HOST` + `PGPORT`/`PGUSER`/
`PGPASSWORD`/`PGDATABASE`, or `DATABASE_URL`, for the upstream database —
when `UPSTREAM_POSTGRESQL_HOST` is set, `DATABASE_URL` is not parsed and can
stay app-facing — plus `POOL_MODE`,
`MAX_CLIENT_CONN`, `DEFAULT_POOL_SIZE`, `MAX_PREPARED_STATEMENTS`, TLS
settings, and the rest — see `entrypoint.sh`). Mounting your own
`/etc/pgbouncer/pgbouncer.ini` skips generation entirely.

## Updating PgBouncer

Bump `ARG VERSION=` in the `Dockerfile`; the workflow derives all image tags
from it.
