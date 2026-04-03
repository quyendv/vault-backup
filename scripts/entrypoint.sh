#!/bin/sh
# If SCHEDULE is set: run vault-backup.sh on a cron via supercronic.
# If SCHEDULE is empty: run vault-backup.sh once and exit.
set -e

if [ -n "${SCHEDULE:-}" ]; then
  mkdir -p /etc/supercronic
  printf '%s /usr/local/bin/vault-backup.sh\n' "$SCHEDULE" > /etc/supercronic/crontab
  exec /usr/local/bin/supercronic -passthrough-logs /etc/supercronic/crontab
fi

exec /usr/local/bin/vault-backup.sh "$@"
