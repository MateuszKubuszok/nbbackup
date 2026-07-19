#!/usr/bin/env bash
# Trigger a Nextbox backup via the local daemon API.
#
# The nextbox-daemon runs on the host (listening on 0.0.0.0:18585) but only
# authorizes callers whose source IP is on its docker network,
# 172.18.238.0/24 (see requires_auth in the daemon). In other words it expects
# to be called from *inside* the Nextcloud compose stack, not from the host:
# a host-originated request to 172.18.238.1 collapses to a 127.0.0.1 source
# and is rejected with "not allowed".
#
# So we issue the API calls with `docker exec` inside a running container on
# that network. The container reaches the daemon at the docker gateway
# (172.18.238.1:18585) and the daemon sees an allowed 172.18.238.x source.
# This talks ONLY to the local daemon over plain HTTP (the daemon has no TLS,
# so there is no certificate to ignore) and only ever *starts* a backup --
# it never restores, so it cannot overwrite live Nextcloud data.
#
# Requirements: run as root or a user in the `docker` group (system cron runs
# as root, which is fine).
#
# Usage:
#   nextbox-backup.sh [TAR_PATH]
#
# TAR_PATH defaults to /media/NextBoxHardDisk/scheduled_backup and must live
# under a mounted Nextbox backup device, or the daemon rejects it.
# Discover devices / existing backups with:
#   docker exec nextbox-compose_app_1 curl http://172.18.238.1:18585/backup
#
# Schedule with crontab -e (root):
#   0 3 * * * /usr/local/bin/nextbox-backup.sh >> /var/log/nextbox-backup-cron.log 2>&1

set -euo pipefail

DAEMON="http://172.18.238.1:18585"        # daemon, as seen from inside the docker network
CONTAINER="nextbox-compose_app_1"         # running container on nextbox-compose_default (172.18.238.0/24)
TAR_PATH="${1:-/media/NextBoxHardDisk/scheduled_backup}"
TIMEOUT=21600  # 6 hours
INTERVAL=30

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Run curl inside the relay container so the daemon sees an authorized source IP.
nbcurl() { docker exec "$CONTAINER" curl "$@"; }

# Preflight: the relay container must be up (this also verifies docker is usable).
if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -qx true; then
    log "ERROR: container '$CONTAINER' is not running (or docker is not accessible); cannot reach the local Nextbox daemon" >&2
    exit 1
fi

log "Starting backup to $TAR_PATH"

if ! RESPONSE=$(nbcurl -sf -X POST --data-urlencode "tar_path=$TAR_PATH" "$DAEMON/backup/start"); then
    log "ERROR: Could not reach Nextbox daemon at $DAEMON via $CONTAINER" >&2
    exit 1
fi
RESULT=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',''))" 2>/dev/null || echo "")

if [ "$RESULT" = "error" ]; then
    MSG=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('msg',[''])[0])" 2>/dev/null || echo "unknown error")
    log "ERROR: Failed to start backup: $MSG" >&2
    exit 1
fi

log "Backup triggered successfully"

ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))

    STATUS=$(nbcurl -sf "$DAEMON/backup/status" 2>/dev/null || echo '{}')
    STATE=$(echo "$STATUS" | python3 -c "
import sys, json
d = json.load(sys.stdin).get('data')
print(d.get('state', 'unknown') if d else 'idle')
" 2>/dev/null || echo "unknown")

    case "$STATE" in
        completed)
            log "Backup completed successfully"
            nbcurl -sf "$DAEMON/backup/status/clear" > /dev/null 2>&1 || true
            exit 0
            ;;
        failed)
            WHO=$(echo "$STATUS" | python3 -c "
import sys, json
d = json.load(sys.stdin).get('data', {})
print(d.get('who', 'unknown'))
" 2>/dev/null || echo "unknown")
            log "ERROR: Backup failed during: $WHO" >&2
            nbcurl -sf "$DAEMON/backup/status/clear" > /dev/null 2>&1 || true
            exit 1
            ;;
        idle)
            log "WARNING: No backup in progress (status cleared externally?)" >&2
            exit 1
            ;;
    esac

    PERCENT=$(echo "$STATUS" | python3 -c "
import sys, json
d = json.load(sys.stdin).get('data', {})
print(d.get('percent', '?'))
" 2>/dev/null || echo "?")
    log "In progress: state=$STATE percent=$PERCENT elapsed=${ELAPSED}s"
done

log "ERROR: Backup timed out after ${TIMEOUT}s" >&2
exit 2
