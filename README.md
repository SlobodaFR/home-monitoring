# home-monitoring

Minimal observability stack for the home-lab: live container view/logs (Dozzle) +
shipping every container's logs to MinIO (Vector). No Prometheus/Grafana/Loki here
on purpose — this repo stays small.

## Stack

- **Dozzle** (`amir20/dozzle:latest`) — live container status + log viewer, with
  simple-auth login and its built-in MCP server enabled.
- **Vector** (`timberio/vector:latest-alpine`) — tails Docker logs via the socket
  (`docker_logs` source) and batches them as gzip-compressed JSON to a MinIO bucket.

Reverse proxy is **Caddy** (host-level systemd service, config dropped in
`/etc/caddy/sites/`), matching the other `home-*` repos — not Traefik.

## Accessing Dozzle

https://dozzle.sloboda.fr — login with the `MONITORING_DOZZLE_USERNAME` /
`MONITORING_DOZZLE_PASSWORD` credentials stored in 1Password.

## Connecting Claude to Dozzle's MCP server

Dozzle exposes an MCP server (Streamable HTTP) at `/api/mcp` when
`DOZZLE_ENABLE_MCP=true` (docs: https://dozzle.dev/guide/mcp). With simple auth
enabled, the MCP endpoint requires a JWT obtained from `/api/token` — there's no
separate MCP API key.

1. Get a token:

   ```bash
   TOKEN=$(curl -s -X POST https://dozzle.sloboda.fr/api/token \
     -H 'Content-Type: application/json' \
     -d '{"username":"<MONITORING_DOZZLE_USERNAME>","password":"<MONITORING_DOZZLE_PASSWORD>"}' \
     | jq -r .token)
   ```

2. Register the MCP server with Claude:

   ```bash
   claude mcp add --transport http dozzle https://dozzle.sloboda.fr/api/mcp \
     --header "Authorization: Bearer $TOKEN"
   ```

JWTs expire, so re-run step 1 and re-add the server when Claude's calls start
getting 401s.

## Where logs land in MinIO

Vector writes into the **same shared MinIO bucket** the other `home-*` repos
already use (`MINIO_BUCKET`), under a `logs/` prefix so it doesn't collide with
their data. Flushes every 5 minutes or 10 MB, whichever comes first, as
gzip-compressed JSON lines. Object key layout:

```
<bucket>/logs/<container_name>/<YYYY-MM-DD>/<uuid>.log.gz
```

One prefix per container per day (Docker/compose container name, e.g.
`home-monitoring-dozzle-1`); multiple objects per day/container as batches
flush.

## Reading logs after the fact

With the [`mc`](https://min.io/docs/minio/linux/reference/minio-mc.html) client:

```bash
mc alias set homelab "$MINIO_ENDPOINT" "$MINIO_ACCESS_KEY_ID" "$MINIO_SECRET_ACCESS_KEY"
mc ls homelab/$MINIO_BUCKET/logs/<container_name>/2026-08-24/
mc cat homelab/$MINIO_BUCKET/logs/<container_name>/2026-08-24/<uuid>.log.gz | gunzip | jq .
```

With the AWS CLI (works against any S3-compatible endpoint):

```bash
aws --endpoint-url "$MINIO_ENDPOINT" s3 ls s3://$MINIO_BUCKET/logs/<container_name>/2026-08-24/
aws --endpoint-url "$MINIO_ENDPOINT" s3 cp s3://$MINIO_BUCKET/logs/<container_name>/2026-08-24/<uuid>.log.gz - | gunzip | jq .
```

## Secrets

No `.env` is committed. The deploy pipeline pulls secrets from 1Password and
writes `.env` on the host at deploy time.

Dozzle's login is repo-specific (`MONITORING_DOZZLE_*`). Vector reuses the
**shared MinIO credentials** (`MINIO_*`) already in the vault from
`home-auth`/`home-budget`/`home-health` — no new MinIO secrets were created.

Dozzle's `data/dozzle/users.yml` (bcrypt-hashed credentials) is generated on the
host on every deploy from `MONITORING_DOZZLE_USERNAME` / `MONITORING_DOZZLE_PASSWORD`
via `docker run amir20/dozzle generate` — see `deploy/scripts/update-vps.sh`.
It is never committed.

### 1Password variables (`TECH/thomassloboda_home_secrets`)

**Dozzle (new)**

| Variable | Purpose |
|---|---|
| `MONITORING_DOZZLE_USERNAME` | Login username for Dozzle simple-auth |
| `MONITORING_DOZZLE_PASSWORD` | Login password (hashed into `users.yml` at deploy time) |

**Vector (reused, already exist)**

| Variable | Purpose |
|---|---|
| `MINIO_ENDPOINT` | MinIO endpoint URL |
| `MINIO_ACCESS_KEY_ID` | MinIO access key |
| `MINIO_SECRET_ACCESS_KEY` | MinIO secret key |
| `MINIO_BUCKET` | Shared bucket (logs land under `logs/` inside it) |
| `MINIO_REGION` | Region string MinIO expects |

Plus the shared `VPS_HOST` / `VPS_USER` / `VPS_PRIVATE_KEY` already used by the
other `home-*` repos' deploy pipelines.
