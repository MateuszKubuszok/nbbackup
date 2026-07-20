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
# TAR_PATH defaults to /media/extra-1/nc_backup and must live under a mounted
# Nextbox backup device, or the daemon rejects it.
# Discover devices / existing backups with:
#   docker exec nextbox-compose_app_1 curl http://172.18.238.1:18585/backup
#
# On success, if the off-site sync script (nextbox-offsite.sh) is installed and
# executable, this hands off to it to push the refreshed mirror to pCloud. Set
# OFFSITE_SCRIPT= (empty) to disable that hand-off.
#
# Schedule with crontab -e (root):
#   0 3 * * * /usr/local/bin/nextbox-backup.sh >> /var/log/nextbox-backup-cron.log 2>&1

set -euo pipefail

DAEMON="http://172.18.238.1:18585"        # daemon, as seen from inside the docker network
CONTAINER="nextbox-compose_app_1"         # running container on nextbox-compose_default (172.18.238.0/24)
TAR_PATH="${1:-/media/extra-1/nc_backup}"
TIMEOUT=21600  # 6 hours
INTERVAL=30

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Run curl inside the relay container so the daemon sees an authorized source IP.
nbcurl() { docker exec "$CONTAINER" curl "$@"; }

# After a successful local backup, hand off to the off-site sync if installed.
# A failure there is logged loudly but does NOT fail the local backup, which has
# already succeeded; the off-site sync is resumable and retries every night.
OFFSITE_SCRIPT="${OFFSITE_SCRIPT-/usr/local/bin/nextbox-offsite.sh}"
run_offsite() {
    [ -n "$OFFSITE_SCRIPT" ] && [ -x "$OFFSITE_SCRIPT" ] || return 0
    log "Handing off to off-site sync: $OFFSITE_SCRIPT"
    if "$OFFSITE_SCRIPT"; then
        log "Off-site sync completed"
    else
        log "WARNING: off-site sync failed (exit $?); local backup is intact, will retry next run" >&2
    fi
}

# The daemon reports which part of the backup is running in the status "who"
# field (desc[0] from full_export() in the daemon's raw_backup_restore.py).
# Map each to a human label. Backup runs these parts in this order:
#   sql -> data -> apps -> nextbox -> config -> letsencrypt
describe_who() {
    case "$1" in
        all)         echo "overall" ;;
        sql)         echo "database dump" ;;
        data)        echo "Nextcloud files (data/)" ;;
        apps)        echo "installed apps (custom_apps/)" ;;
        nextbox)     echo "NextBox system config" ;;
        config)      echo "Nextcloud config" ;;
        letsencrypt) echo "TLS certificates" ;;
        *)           echo "$1" ;;
    esac
}

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

# Each part moves through state: starting -> active -> finished; the overall
# run ends in "completed". Between a part's "finished" and the next part's
# "active" the daemon runs a blocking `rsync --dry-run` to count files and
# pushes no status update, so the status legitimately sits at the previous
# part's "finished/100" for minutes on a large data/ tree -- that is the
# daemon counting files, not a stall.
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))

    STATUS=$(nbcurl -sf "$DAEMON/backup/status" 2>/dev/null || echo '{}')
    # Parse state, who (current part) and percent in one shot; "idle" == no
    # backup on the board (data is null).
    PARSED=$(echo "$STATUS" | python3 -c "
import sys, json
d = json.load(sys.stdin).get('data')
if not d:
    print('idle ? ?')
else:
    print(d.get('state', 'unknown'), d.get('who', '?'), d.get('percent', '?'))
" 2>/dev/null || echo "unknown ? ?")
    read -r STATE WHO PERCENT <<<"$PARSED"
    WHO_DESC=$(describe_who "$WHO")

    case "$STATE" in
        completed)
            log "Backup completed successfully (all parts exported)"
            nbcurl -sf "$DAEMON/backup/status/clear" > /dev/null 2>&1 || true
            run_offsite
            exit 0
            ;;
        failed)
            log "ERROR: Backup FAILED while backing up ${WHO_DESC} (who=$WHO)" >&2
            nbcurl -sf "$DAEMON/backup/status/clear" > /dev/null 2>&1 || true
            exit 1
            ;;
        idle)
            log "WARNING: No backup in progress (status cleared externally?)" >&2
            exit 1
            ;;
    esac

    # Human-readable progress line, driven by the (state, who) pair.
    case "$STATE" in
        starting)
            MSG="starting up (dumping database first)" ;;
        active)
            if [ "$PERCENT" = "100" ]; then
                MSG="backing up ${WHO_DESC} (~100%; the estimate saturates on incremental syncs, still transferring)"
            else
                MSG="backing up ${WHO_DESC} (${PERCENT}%)"
            fi ;;
        finished)
            MSG="finished ${WHO_DESC}; preparing next part (scanning files, no status update meanwhile)" ;;
        inactive)
            MSG="preparing ${WHO_DESC}" ;;
        *)
            MSG="${WHO_DESC}: state=${STATE} percent=${PERCENT}" ;;
    esac
    log "In progress: ${MSG} — elapsed ${ELAPSED}s"
done

log "ERROR: Backup timed out after ${TIMEOUT}s" >&2
exit 2
