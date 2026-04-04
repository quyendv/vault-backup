# Least privilege for scripts/vault-backup.sh (vault operator raft snapshot save).
#
#   vault policy write backup-raft policies/backup-raft.hcl
#   vault token create -policy=backup-raft -period=24h -orphan
#
# Use the token value as VAULT_TOKEN (or write it to VAULT_TOKEN_FILE).
# Periodic tokens: renew before the period ends (e.g. vault token renew) or rotate the secret.
#
# Restore (vault-restore.sh) needs a different, much stronger policy — do not use this token for restore.

path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}

# Include if /v1/sys/health is not served anonymously in your deployment.
path "sys/health" {
  capabilities = ["read"]
}

# Optional: allow the job to renew this periodic token before it expires.
path "auth/token/renew-self" {
  capabilities = ["update"]
}
