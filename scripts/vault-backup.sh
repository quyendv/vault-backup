#!/usr/bin/env bash
# =============================================================================
# vault-backup.sh - Vault Raft snapshot backup to S3-compatible storage
#
# Works with: MinIO, OVH Object Storage, AWS S3, Ceph RGW, Cloudflare R2, ...
#
# Usage: ./vault-backup.sh [--dry-run]
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment or a sourced .env file)
# ---------------------------------------------------------------------------
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-/etc/vault/backup-token}"

BACKUP_DIR="${BACKUP_DIR:-/var/backups/vault}"
LOG_FILE="${LOG_FILE:-/var/log/vault-backup.log}"
RETENTION_LOCAL_DAYS="${RETENTION_LOCAL_DAYS:-3}"

# S3-compatible storage
# S3_BUCKET     - bucket name only (no s3:// prefix, no path)
# S3_PREFIX     - optional key prefix inside the bucket (no leading/trailing slash)
# S3_ENDPOINT   - full storage endpoint URL (required for non-AWS)
# S3_ACCESS_KEY / S3_SECRET_KEY - leave empty to use ~/.aws or instance role
# S3_REGION     - region hint (default: us-east-1)
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-vault-snapshots}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-}"
S3_SECRET_KEY="${S3_SECRET_KEY:-}"
S3_REGION="${S3_REGION:-us-east-1}"
RETENTION_S3_DAYS="${RETENTION_S3_DAYS:-30}"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
SNAPSHOT_NAME="vault-snapshot-${TIMESTAMP}.snap"
SNAPSHOT_GZ="${SNAPSHOT_NAME}.gz"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*" | tee -a "$LOG_FILE"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*" | tee -a "$LOG_FILE"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" | tee -a "$LOG_FILE" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# S3 helpers - aws CLI args for any S3-compatible provider
# ---------------------------------------------------------------------------

s3_args() {
  local args=(--region "$S3_REGION")
  [[ -n "$S3_ENDPOINT" ]] && args+=(--endpoint-url "$S3_ENDPOINT")
  echo "${args[@]}"
}

s3_export_creds() {
  if [[ -n "$S3_ACCESS_KEY" && -n "$S3_SECRET_KEY" ]]; then
    export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
    unset AWS_PROFILE AWS_DEFAULT_PROFILE
  fi
}

normalize_prefix() {
  local p="${1:-}"
  p="${p#/}"
  p="${p%/}"
  echo "$p"
}

# Build object key: prefix=vault-snapshots, file=snap.gz -> vault-snapshots/snap.gz
s3_object_key() {
  local filename="$1"
  local prefix
  prefix=$(normalize_prefix "$S3_PREFIX")
  if [[ -n "$prefix" ]]; then
    echo "${prefix}/${filename}"
  else
    echo "${filename}"
  fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
resolve_vault_token() {
  if [[ -n "$VAULT_TOKEN" ]]; then
    echo "$VAULT_TOKEN"
  elif [[ -f "$VAULT_TOKEN_FILE" ]]; then
    cat "$VAULT_TOKEN_FILE"
  else
    die "No VAULT_TOKEN or VAULT_TOKEN_FILE found"
  fi
}

check_deps() {
  local missing=()
  for cmd in vault gzip sha256sum curl; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ -n "$S3_BUCKET" ]]; then
    command -v aws &>/dev/null || missing+=("awscli")
  fi
  [[ ${#missing[@]} -eq 0 ]] || die "Missing dependencies: ${missing[*]}"
}

check_vault_health() {
  local status
  status=$(curl -sf "${VAULT_ADDR}/v1/sys/health" 2>/dev/null || echo "{}")
  local initialized sealed
  initialized=$(echo "$status" | grep -o '"initialized":[^,}]*' | cut -d: -f2 | tr -d ' ')
  sealed=$(echo "$status" | grep -o '"sealed":[^,}]*' | cut -d: -f2 | tr -d ' ')
  [[ "$initialized" == "true" ]] || die "Vault is not initialized"
  [[ "$sealed"      == "false" ]] || die "Vault is sealed - cannot take snapshot"
  log "Vault health OK (initialized=true, sealed=false)"
}

# ---------------------------------------------------------------------------
# Main backup flow
# ---------------------------------------------------------------------------
main() {
  log "========================================"
  log "Starting Vault backup (dry_run=$DRY_RUN)"

  check_deps
  check_vault_health

  local TOKEN
  TOKEN=$(resolve_vault_token)
  export VAULT_TOKEN="$TOKEN"

  mkdir -p "$BACKUP_DIR"
  local SNAP_PATH="${BACKUP_DIR}/${SNAPSHOT_NAME}"
  local GZ_PATH="${BACKUP_DIR}/${SNAPSHOT_GZ}"
  local CHECKSUM_FILE="${GZ_PATH}.sha256"

  log "Taking Raft snapshot -> $SNAP_PATH"
  if ! $DRY_RUN; then
    vault operator raft snapshot save "$SNAP_PATH" \
      || die "vault snapshot save failed"
    log "Snapshot saved: $(du -sh "$SNAP_PATH" | cut -f1)"
  else
    log "[DRY RUN] vault operator raft snapshot save $SNAP_PATH"
  fi

  log "Compressing -> $GZ_PATH"
  if ! $DRY_RUN; then
    gzip -9 "$SNAP_PATH"
    log "Compressed: $(du -sh "$GZ_PATH" | cut -f1)"
  else
    log "[DRY RUN] gzip -9 $SNAP_PATH"
  fi

  if ! $DRY_RUN; then
    sha256sum "$GZ_PATH" > "$CHECKSUM_FILE"
    log "Checksum: $(cat "$CHECKSUM_FILE")"
  fi

  if [[ -n "$S3_BUCKET" ]]; then
    s3_export_creds
    upload_to_s3 "$GZ_PATH" "$CHECKSUM_FILE"
  else
    warn "S3_BUCKET not set - keeping local backup only"
  fi

  cleanup_local
  [[ -n "$S3_BUCKET" ]] && cleanup_s3

  log "Backup complete: ${SNAPSHOT_GZ}"
  log "========================================"
}

upload_to_s3() {
  local GZ_PATH="$1"
  local CHECKSUM_FILE="$2"

  local OBJ_KEY SUM_KEY
  OBJ_KEY=$(s3_object_key "$SNAPSHOT_GZ")
  SUM_KEY=$(s3_object_key "${SNAPSHOT_GZ}.sha256")

  local DEST="s3://${S3_BUCKET}/${OBJ_KEY}"
  log "Uploading -> $DEST"

  # shellcheck disable=SC2046
  if ! $DRY_RUN; then
    aws s3 cp $(s3_args) "$GZ_PATH" "$DEST" \
      || die "S3 upload failed"

    aws s3 cp $(s3_args) "$CHECKSUM_FILE" "s3://${S3_BUCKET}/${SUM_KEY}" \
      || warn "Checksum upload failed (non-fatal)"

    log "Upload OK -> $DEST"
  else
    log "[DRY RUN] aws s3 cp $GZ_PATH $DEST"
  fi
}

cleanup_local() {
  log "Cleaning local backups older than ${RETENTION_LOCAL_DAYS} days"
  if ! $DRY_RUN; then
    find "$BACKUP_DIR" -name "vault-snapshot-*.snap.gz*" \
      -mtime +"$RETENTION_LOCAL_DAYS" -delete -print \
      | while read -r f; do log "Deleted local: $f"; done
  else
    log "[DRY RUN] Would prune local files older than ${RETENTION_LOCAL_DAYS} days"
  fi
}

cleanup_s3() {
  log "Cleaning S3 objects older than ${RETENTION_S3_DAYS} days in s3://${S3_BUCKET}/$(normalize_prefix "$S3_PREFIX")"

  if $DRY_RUN; then
    log "[DRY RUN] Would prune S3 objects older than ${RETENTION_S3_DAYS} days"
    return
  fi

  local CUTOFF_EPOCH
  CUTOFF_EPOCH=$(date -d "${RETENTION_S3_DAYS} days ago" +%s 2>/dev/null \
    || date -v-"${RETENTION_S3_DAYS}"d +%s)

  local PREFIX_ARG
  PREFIX_ARG=$(normalize_prefix "$S3_PREFIX")
  [[ -n "$PREFIX_ARG" ]] && PREFIX_ARG="${PREFIX_ARG}/"

  # aws s3 ls: "2024-09-01 02:00:05   123456 vault-snapshot-....snap.gz"
  # shellcheck disable=SC2046
  aws s3 ls $(s3_args) "s3://${S3_BUCKET}/${PREFIX_ARG}" 2>/dev/null \
    | grep "vault-snapshot-" \
    | while read -r DATE TIME _SIZE FILENAME; do
        local OBJ_EPOCH
        OBJ_EPOCH=$(date -d "${DATE} ${TIME}" +%s 2>/dev/null \
          || date -j -f "%Y-%m-%d %H:%M:%S" "${DATE} ${TIME}" +%s 2>/dev/null || echo 0)
        if (( OBJ_EPOCH > 0 && OBJ_EPOCH < CUTOFF_EPOCH )); then
          local FULL_KEY="${PREFIX_ARG}${FILENAME}"
          log "Deleting s3://${S3_BUCKET}/${FULL_KEY}"
          # shellcheck disable=SC2046
          aws s3 rm $(s3_args) "s3://${S3_BUCKET}/${FULL_KEY}" \
            || warn "Failed to delete ${FULL_KEY}"
        fi
      done
}

main "$@"
