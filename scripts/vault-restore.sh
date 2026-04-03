#!/usr/bin/env bash
# =============================================================================
# vault-restore.sh - Restore Vault Raft snapshot from S3-compatible storage
#
# Works with: MinIO, OVH Object Storage, AWS S3, Ceph RGW, Cloudflare R2, ...
#
# Usage:
#   ./vault-restore.sh --file /path/to/vault-snapshot-YYYYMMDD_HHMMSS.snap.gz
#   ./vault-restore.sh --s3-key vault-snapshot-20240901_020000.snap.gz
#   ./vault-restore.sh --latest
# =============================================================================
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-/etc/vault/backup-token}"

# Must match vault-backup.sh
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-vault-snapshots}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-}"
S3_SECRET_KEY="${S3_SECRET_KEY:-}"
S3_REGION="${S3_REGION:-us-east-1}"

WORK_DIR="${WORK_DIR:-/tmp/vault-restore-$$}"
LOG_FILE="${LOG_FILE:-/var/log/vault-restore.log}"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*" | tee -a "$LOG_FILE"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*" | tee -a "$LOG_FILE"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" | tee -a "$LOG_FILE" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --file PATH       Restore from a local .snap or .snap.gz file
  --s3-key KEY      RUN/vault-snapshot-....snap.gz under S3_PREFIX, or basename only if it
                    contains vault-snapshot-<RUN>.snap.gz (RUN = YYYYMMDD_HHMMSS)
  --latest          Download and restore the newest snapshot from S3
  --force           Skip confirmation prompt
  -h, --help        Show this help

Environment (S3-compatible):
  VAULT_ADDR        Vault API address (default: http://127.0.0.1:8200)
  VAULT_TOKEN       Vault token (or use VAULT_TOKEN_FILE)
  S3_BUCKET         Bucket name
  S3_PREFIX         Key prefix inside bucket (default: vault-snapshots)
  S3_ENDPOINT       Endpoint URL (e.g. https://minio.example.com)
  S3_ACCESS_KEY     Access key ID
  S3_SECRET_KEY     Secret access key
  S3_REGION         Region (default: us-east-1)
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# S3 helpers (same contract as vault-backup.sh)
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
  p="${p#/}"; p="${p%/}"
  echo "$p"
}

# Relative path under S3_PREFIX (e.g. 20260305_020000/vault-snapshot-....snap.gz)
s3_key_under_prefix() {
  local rel="${1#/}"
  local prefix
  prefix=$(normalize_prefix "$S3_PREFIX")
  if [[ -n "$prefix" ]]; then
    echo "${prefix}/${rel}"
  else
    echo "${rel}"
  fi
}

snap_ts_from_basename() {
  local f="$1"
  if [[ "$f" =~ vault-snapshot-([0-9]{8}_[0-9]{6})\.snap\.gz$ ]]; then
    echo "${BASH_REMATCH[1]}"
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
  command -v vault     &>/dev/null || missing+=(vault)
  command -v gzip      &>/dev/null || missing+=(gzip)
  command -v sha256sum &>/dev/null || missing+=(sha256sum)
  if [[ -n "$S3_BUCKET" ]]; then
    command -v aws &>/dev/null || missing+=(awscli)
  fi
  [[ ${#missing[@]} -eq 0 ]] || die "Missing dependencies: ${missing[*]}"
}

confirm() {
  [[ "${FORCE:-false}" == "true" ]] && return 0
  echo ""
  warn "+--------------------------------------------------+"
  warn "| WARNING: Restoring overwrites all Vault data.   |"
  warn "| This operation is irreversible.                   |"
  warn "+--------------------------------------------------+"
  echo ""
  read -rp "  Type 'yes' to continue: " ANSWER
  [[ "$ANSWER" == "yes" ]] || die "Restore cancelled by user"
}

# ---------------------------------------------------------------------------
# S3 operations
# ---------------------------------------------------------------------------
get_latest_s3_key() {
  [[ -n "$S3_BUCKET" ]] || die "S3_BUCKET is not set"

  local prefix_arg
  prefix_arg=$(normalize_prefix "$S3_PREFIX")
  [[ -n "$prefix_arg" ]] && prefix_arg="${prefix_arg}/"

  log "Scanning s3://${S3_BUCKET}/${prefix_arg} for latest snapshot"

  local runs=() line
  # shellcheck disable=SC2046
  while IFS= read -r line; do
    [[ "$line" =~ PRE[[:space:]]+([0-9]{8}_[0-9]{6})/ ]] && runs+=("${BASH_REMATCH[1]}")
  done < <(aws s3 ls $(s3_args) "s3://${S3_BUCKET}/${prefix_arg}" --delimiter / 2>/dev/null || true)

  [[ ${#runs[@]} -gt 0 ]] || die "No run folders (YYYYMMDD_HHMMSS/) under s3://${S3_BUCKET}/${prefix_arg}"

  local latest_run inner_line filename
  latest_run=$(printf '%s\n' "${runs[@]}" | sort | tail -1)
  # shellcheck disable=SC2046
  inner_line=$(aws s3 ls $(s3_args) "s3://${S3_BUCKET}/${prefix_arg}${latest_run}/" 2>/dev/null \
    | grep '\.snap\.gz$' | sort | tail -1)
  [[ -n "$inner_line" ]] || die "No .snap.gz inside s3://${S3_BUCKET}/${prefix_arg}${latest_run}/"
  filename=$(echo "$inner_line" | awk '{print $NF}')
  log "Latest: s3://${S3_BUCKET}/${prefix_arg}${latest_run}/${filename}"
  echo "${prefix_arg}${latest_run}/${filename}"
}

download_from_s3() {
  local FULL_KEY="$1"
  local FILENAME
  FILENAME=$(basename "$FULL_KEY")
  local LOCAL_FILE="${WORK_DIR}/${FILENAME}"

  mkdir -p "$WORK_DIR"

  log "Downloading s3://${S3_BUCKET}/${FULL_KEY} -> $LOCAL_FILE"
  # shellcheck disable=SC2046
  aws s3 cp $(s3_args) "s3://${S3_BUCKET}/${FULL_KEY}" "$LOCAL_FILE" \
    || die "S3 download failed"

  local SUM_KEY="${FULL_KEY}.sha256"
  local SUM_FILE="${LOCAL_FILE}.sha256"
  # shellcheck disable=SC2046
  if aws s3 cp $(s3_args) "s3://${S3_BUCKET}/${SUM_KEY}" "$SUM_FILE" 2>/dev/null; then
    log "Verifying checksum..."
    echo "$(awk '{print $1}' "$SUM_FILE")  ${FILENAME}" > "${SUM_FILE}.local"
    (cd "$WORK_DIR" && sha256sum -c "${FILENAME}.sha256.local") \
      || die "Checksum verification FAILED - snapshot may be corrupt"
    log "Checksum OK"
  else
    warn "No checksum sidecar found - skipping verification"
  fi

  echo "$LOCAL_FILE"
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------
do_restore() {
  local SNAP_FILE="$1"

  local RAW_SNAP="$SNAP_FILE"
  if [[ "$SNAP_FILE" == *.gz ]]; then
    log "Decompressing $SNAP_FILE"
    RAW_SNAP="${SNAP_FILE%.gz}"
    gunzip -c "$SNAP_FILE" > "$RAW_SNAP"
    log "Decompressed -> $RAW_SNAP ($(du -sh "$RAW_SNAP" | cut -f1))"
  fi

  local TOKEN
  TOKEN=$(resolve_vault_token)
  export VAULT_TOKEN="$TOKEN"

  log "Restoring snapshot: $RAW_SNAP"
  vault operator raft snapshot restore -force "$RAW_SNAP" \
    || die "vault snapshot restore failed"

  log "Restore complete. Verifying Vault health..."
  sleep 2
  local STATUS
  STATUS=$(curl -sf "${VAULT_ADDR}/v1/sys/health" 2>/dev/null || echo "{}")
  local SEALED
  SEALED=$(echo "$STATUS" | grep -o '"sealed":[^,}]*' | cut -d: -f2 | tr -d ' ')

  if [[ "$SEALED" == "false" ]]; then
    log "Vault is running and unsealed - restore successful"
  elif [[ "$SEALED" == "true" ]]; then
    warn "Vault is sealed after restore - unseal manually: vault operator unseal"
  else
    warn "Could not verify Vault status - check manually"
  fi
}

cleanup() { [[ -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
LOCAL_FILE=""
S3_KEY_ARG=""
USE_LATEST=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)    LOCAL_FILE="$2";  shift 2 ;;
    --s3-key)  S3_KEY_ARG="$2"; shift 2 ;;
    --latest)  USE_LATEST=true;  shift   ;;
    --force)   FORCE=true;       shift   ;;
    -h|--help) usage ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
check_deps

log "========================================"
log "Vault Restore"

if [[ -n "$S3_BUCKET" ]]; then
  s3_export_creds
fi

if $USE_LATEST; then
  [[ -n "$S3_BUCKET" ]] || die "--latest requires S3_BUCKET to be set"
  S3_KEY_ARG=$(get_latest_s3_key)
  LOCAL_FILE=$(download_from_s3 "$S3_KEY_ARG")

elif [[ -n "$S3_KEY_ARG" ]]; then
  [[ -n "$S3_BUCKET" ]] || die "--s3-key requires S3_BUCKET to be set"
  if [[ "$S3_KEY_ARG" == */* ]]; then
    full_key=$(s3_key_under_prefix "$S3_KEY_ARG")
  else
    ts=$(snap_ts_from_basename "$S3_KEY_ARG")
    [[ -n "$ts" ]] || die "--s3-key must be RUN/snapshot.snap.gz or vault-snapshot-<RUN>.snap.gz"
    full_key=$(s3_key_under_prefix "${ts}/${S3_KEY_ARG}")
  fi
  LOCAL_FILE=$(download_from_s3 "$full_key")
fi

[[ -n "$LOCAL_FILE" ]] || die "No source provided. Use --file, --s3-key, or --latest"
[[ -f "$LOCAL_FILE"  ]] || die "File not found: $LOCAL_FILE"

log "Source: $LOCAL_FILE ($(du -sh "$LOCAL_FILE" | cut -f1))"
confirm
do_restore "$LOCAL_FILE"

log "========================================"
