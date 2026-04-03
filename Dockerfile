# Vault Raft snapshot backup to S3-compatible storage.
# Intended for linux/amd64 (e.g. Ubuntu). Build with: docker build --platform linux/amd64 .
# SCHEDULE: supercronic in-container; empty = one-shot (see README).
FROM hashicorp/vault:1.18

USER root

RUN apk add --no-cache \
    bash \
    curl \
    gzip \
    findutils \
    coreutils \
    ca-certificates \
    aws-cli

ARG SUPERCRONIC_VERSION=v0.2.34

RUN curl -fsSL -o /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
  && chmod +x /usr/local/bin/supercronic

COPY scripts/vault-backup.sh /usr/local/bin/vault-backup.sh
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
# Normalize CRLF when the repo is checked out on Windows
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh /usr/local/bin/vault-backup.sh \
  && chmod +x /usr/local/bin/vault-backup.sh /usr/local/bin/entrypoint.sh

WORKDIR /backup

ENV BACKUP_DIR=/backup \
    LOG_FILE=/backup/vault-backup.log

# CMD [] is required: the base image sets its own CMD; without clearing it, Docker would pass that
# command as arguments to ENTRYPOINT (breaking this wrapper).
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
