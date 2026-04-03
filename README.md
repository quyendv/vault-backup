# vault-backup

Docker image and shell scripts to back up **HashiCorp Vault** Raft snapshots to **S3-compatible** storage (MinIO, AWS S3, OVH Object Storage, Cloudflare R2, Ceph RGW, etc.).

**Features**

- `vault operator raft snapshot save`, gzip compression, optional `sha256` sidecar upload
- Upload via AWS CLI v2 (same env pattern as other S3 tools)
- Retention: local and remote pruning by age
- Optional in-container scheduler via **supercronic** — set `SCHEDULE` for periodic runs, or omit for a single run
- Image ships Vault CLI, `aws`, `bash`, and supercronic — nothing to install on the host
- **linux/amd64** only (typical Ubuntu / server Linux)

Published image: `ghcr.io/quyendv/vault-backup` (see [repository](https://github.com/quyendv/vault-backup)).

---

## Quickstart

### Run once (one-off backup)

```bash
docker run --rm \
  -e VAULT_ADDR=http://vault.example.com:8200 \
  -e VAULT_TOKEN=your-token \
  -e S3_BUCKET=my-backups \
  -e S3_ACCESS_KEY=xxx \
  -e S3_SECRET_KEY=xxx \
  -e S3_ENDPOINT=https://minio.example.com \
  -e S3_REGION=us-east-1 \
  -e S3_PREFIX=vault-snapshots \
  -e RETENTION_S3_DAYS=30 \
  ghcr.io/quyendv/vault-backup:latest
```

Local-only (no S3): omit `S3_BUCKET` and related variables; snapshots stay under `BACKUP_DIR` (default `/backup` in the image).

### Run on a schedule (cron inside the container)

```bash
docker run -d \
  -e VAULT_ADDR=http://vault.example.com:8200 \
  -e VAULT_TOKEN=your-token \
  -e S3_BUCKET=my-backups \
  -e S3_SECRET_KEY=xxx \
  -e S3_ACCESS_KEY=xxx \
  -e S3_ENDPOINT=https://minio.example.com \
  -e SCHEDULE="0 */4 * * *" \
  --restart unless-stopped \
  ghcr.io/quyendv/vault-backup:latest
```

Dry run: append `--dry-run` after the image name (`docker run ... ghcr.io/... --dry-run`).

---

## Docker Compose (recommended)

```bash
cp .env.example .env
# Edit .env, then:

docker compose build
docker compose run --rm vault-backup
docker compose run --rm vault-backup --dry-run
```

**Scheduled service:** set `SCHEDULE` and `RESTART_POLICY=unless-stopped` in `.env`, then `docker compose up -d`. Leave `SCHEDULE` unset for one-shot `docker compose run` only.

From a container on Docker Desktop, `VAULT_ADDR` often needs `http://host.docker.internal:8200` (see `docker-compose.yml`).

---

## Installation on Ubuntu

### Option A — Docker Compose

Same as above: configure `.env`, then `docker compose up -d` or `docker compose run --rm vault-backup`.

### Option B — Docker + host crontab (no `SCHEDULE` in the container)

```bash
docker pull ghcr.io/quyendv/vault-backup:latest
# Write env to a file, then e.g. every 4 hours:
0 */4 * * * docker run --rm --env-file /opt/vault-backup/.env -v vault_backup_data:/backup ghcr.io/quyendv/vault-backup:latest >> /var/log/vault-backup.log 2>&1
```

### Option C — Scripts on the host (no container)

Install `vault`, `curl`, `gzip`, `sha256sum`, and `aws` CLI if using S3. Export the same variables as below, then:

```bash
chmod +x scripts/vault-backup.sh scripts/vault-restore.sh
./scripts/vault-backup.sh
./scripts/vault-restore.sh --help
```

---

## Environment variables

| Variable | Required | Default | Description |
| -------- | -------- | ------- | ----------- |
| `VAULT_ADDR` | yes* | `http://127.0.0.1:8200` | Vault API address |
| `VAULT_TOKEN` | one of token / file | — | Token with permission to take Raft snapshots |
| `VAULT_TOKEN_FILE` | one of token / file | `/etc/vault/backup-token` | File containing the token |
| `S3_BUCKET` | no† | — | Bucket name (omit for local-only backup) |
| `S3_PREFIX` | no | `vault-snapshots` | Key prefix inside the bucket |
| `S3_ENDPOINT` | for non-AWS | — | e.g. `https://minio.example.com` |
| `S3_ACCESS_KEY` | with S3 | — | Access key |
| `S3_SECRET_KEY` | with S3 | — | Secret key |
| `S3_REGION` | no | `us-east-1` | Region string for the AWS CLI |
| `RETENTION_LOCAL_DAYS` | no | `3` | Delete older snapshots under `BACKUP_DIR` |
| `RETENTION_S3_DAYS` | no | `30` | Delete older snapshot objects in S3 |
| `BACKUP_DIR` | no | `/backup` (image) | Local directory for snapshots |
| `LOG_FILE` | no | `/backup/vault-backup.log` (image) | Log file path |
| `SCHEDULE` | no | _(empty)_ | Cron expression; if empty, run once and exit |

\*Required in the sense that Vault must be reachable; defaults assume localhost.  
†If unset, backups are kept only on local disk.

### `SCHEDULE` examples

| Value | Meaning |
| ----- | ------- |
| `0 */4 * * *` | Every 4 hours |
| `0 2 * * *` | Daily at 02:00 UTC |
| `0 2 * * 0` | Every Sunday at 02:00 UTC |
| `@every 6h` | Every 6 hours (supercronic extension) |
| _(empty)_ | Run once and exit |

---

## Docker image tags

Images are built from [github.com/quyendv/vault-backup](https://github.com/quyendv/vault-backup) and pushed to GHCR. Typical tags: `latest` on the default branch, semver tags on `v*` Git tags, and a short SHA tag. Pull: `docker pull ghcr.io/quyendv/vault-backup:latest`.

---

## Kubernetes

Use a **CronJob** so each run is a one-shot Job (do **not** set `SCHEDULE` inside the container). Example: [`k8s/cronjob.yaml`](k8s/cronjob.yaml).

```bash
kubectl apply -f k8s/cronjob.yaml
```

---

## Backup layout on S3

Each run uploads **two objects** under a **timestamp folder** (same `TIMESTAMP` as in the filename):

| Object | Purpose |
| ------ | ------- |
| `vault-snapshot-<TIMESTAMP>.snap.gz` | Compressed Raft snapshot (the actual backup). |
| `vault-snapshot-<TIMESTAMP>.snap.gz.sha256` | SHA-256 checksum file for integrity checks on restore. |

Layout:

```
s3://BUCKET/S3_PREFIX/
├── 20260305_020000/
│   ├── vault-snapshot-20260305_020000.snap.gz
│   └── vault-snapshot-20260305_020000.snap.gz.sha256
├── 20260305_060000/
│   └── ...
└── ...
```

Retention deletes **whole run folders** when the folder timestamp is older than `RETENTION_S3_DAYS`.

---

## Restore

Use the host script (or copy it into a throwaway container with the Vault CLI):

```bash
./scripts/vault-restore.sh --file /path/to/vault-snapshot-....snap.gz
./scripts/vault-restore.sh --latest    # needs S3_* set
./scripts/vault-restore.sh --s3-key 20260305_020000/vault-snapshot-20260305_020000.snap.gz
./scripts/vault-restore.sh --s3-key vault-snapshot-20260305_020000.snap.gz   # resolves run folder from name
```

See `scripts/vault-restore.sh --help` for other options.
