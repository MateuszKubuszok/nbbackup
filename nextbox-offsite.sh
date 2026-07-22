#!/usr/bin/env bash
# Off-site, encrypted, versioned backup of the local NextBox mirror to pCloud.
#
# The nightly local backup (nextbox-backup.sh) refreshes an rsync mirror on the
# external disk at /media/extra-1/nc_backup. This script pushes that mirror
# off-site into a restic repository stored on pCloud, reached via rclone:
#
#   /media/extra-1/nc_backup --restic(encrypt+dedup+snapshot)--> rclone:pcloud
#
# restic encrypts client-side (pCloud only ever stores ciphertext), keeps
# point-in-time snapshots, and deduplicates. rclone is only the transport to
# pCloud's OAuth API. This script only ever *writes* snapshots and prunes old
# ones per the retention policy; it never restores, so it cannot damage data.
#
# One-time setup (see README, "Off-site backup") must already be done:
#   - rclone remote `pcloud` configured (/root/.config/rclone/rclone.conf)
#   - restic repo initialised once: `restic init` with the RESTIC_* env below
#   - the repo password saved BOTH in the password file AND your password
#     manager -- lose the password and the backup is unrecoverable.
#
# Runs automatically after a successful local backup (nextbox-backup.sh hands
# off to it), or standalone as root:  sudo /usr/local/bin/nextbox-offsite.sh

set -euo pipefail

# ---- Tunables (override in /etc/default/nextbox-offsite) --------------------
SOURCE="${SOURCE:-/media/extra-1/nc_backup}"
export RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-rclone:pcloud:nextbox-restic}"
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/root/.config/restic/password}"
# Keep restic's metadata cache OFF the SD card (flash wear) -- put it on the
# external disk, as a sibling of nc_backup so it is never itself backed up.
export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/media/extra-1/.restic-cache}"
# restic shells out to rclone; root's cron env is bare, so point at the config.
export RCLONE_CONFIG="${RCLONE_CONFIG:-/root/.config/rclone/rclone.conf}"
# Repo is v2 (compression-capable). "auto" skips already-compressed media;
# set "max" to trade Pi CPU for fewer bytes over the slow pCloud uplink.
export RESTIC_COMPRESSION="${RESTIC_COMPRESSION:-auto}"

# Cap the CPU cores restic may saturate (compression + SHA-256 chunking + AES).
# `nice` only re-prioritises; it does NOT stop restic pinning every core, which
# makes Nextcloud unusable during the multi-day seed. GOMAXPROCS bounds restic's
# parallel worker threads instead, leaving cores free. Default: half the cores
# (min 1); set RESTIC_CPUS=1 for maximum responsiveness (slower backup).
NCPU="$(nproc 2>/dev/null || echo 2)"
RESTIC_CPUS="${RESTIC_CPUS:-$(( NCPU >= 2 ? NCPU / 2 : 1 ))}"

# Upload throttle in KiB/s (0 = unlimited). The first seed runs for days and
# bleeds into daytime, so cap it to keep the home uplink usable.
LIMIT_UPLOAD="${LIMIT_UPLOAD:-4096}"

# Retention: snapshots kept after each nightly `forget`.
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-5}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"
KEEP_YEARLY="${KEEP_YEARLY:-3}"

# `prune` repacks the repo, which over a slow pCloud link means downloading and
# reuploading packs -- expensive -- so it runs only one day a week.
PRUNE_DOW="${PRUNE_DOW:-7}"                 # day-of-week to prune (1=Mon..7=Sun)
PRUNE_MAX_REPACK="${PRUNE_MAX_REPACK:-5G}" # cap repack volume per prune run

[ -r /etc/default/nextbox-offsite ] && . /etc/default/nextbox-offsite
export GOMAXPROCS="$RESTIC_CPUS"   # after sourcing, so /etc/default can override
# ---------------------------------------------------------------------------

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] offsite: $*"; }

# Be a good citizen: lowest CPU priority + idle IO class so the nightly upload
# never starves Nextcloud or the disk. We exec restic's *absolute path* (set in
# preflight): nice/ionice run a real binary, so the shell builtin `command`
# can't be used here to dodge the recursion into this same-named function.
restic() { nice -n 19 ionice -c3 "$RESTIC_BIN" "$@"; }

LIMIT_ARGS=()
[ "${LIMIT_UPLOAD:-0}" -gt 0 ] && LIMIT_ARGS=(--limit-upload "$LIMIT_UPLOAD")

# ---- Preflight -------------------------------------------------------------
# Resolve restic's absolute path with the shell builtin (works here; nice/ionice
# will exec this path directly, see the restic() wrapper above).
RESTIC_BIN="$(command -v restic 2>/dev/null)" || { log "ERROR: restic not installed" >&2; exit 1; }
command -v rclone >/dev/null 2>&1 || { log "ERROR: rclone not installed" >&2; exit 1; }
[ -d "$SOURCE" ] || { log "ERROR: source $SOURCE not found (is the external disk mounted?)" >&2; exit 1; }
[ -r "$RESTIC_PASSWORD_FILE" ] || { log "ERROR: password file $RESTIC_PASSWORD_FILE missing/unreadable" >&2; exit 1; }

mkdir -p "$RESTIC_CACHE_DIR"

# Verify the repo opens before we start (also fails clearly if `restic init`
# was never run, or rclone/pcloud auth is broken).
if ! restic cat config >/dev/null 2>&1; then
    log "ERROR: cannot open restic repo $RESTIC_REPOSITORY -- run 'restic init' once, or check rclone/pcloud auth" >&2
    exit 1
fi

# ---- Backup ----------------------------------------------------------------
log "Starting off-site snapshot: $SOURCE -> $RESTIC_REPOSITORY (upload cap: ${LIMIT_UPLOAD} KiB/s)"
rc=0
restic backup "$SOURCE" \
    --tag nightly \
    --host nextbox \
    --one-file-system \
    "${LIMIT_ARGS[@]}" || rc=$?

# restic: 0 = ok, 3 = completed but some files were unreadable, else = error.
case "$rc" in
    0) log "Snapshot complete" ;;
    3) log "WARNING: snapshot complete but some files were unreadable (exit 3)" >&2 ;;
    *) log "ERROR: restic backup failed (exit $rc)" >&2; exit "$rc" ;;
esac

# ---- Retention (cheap: deletes snapshot metadata only, no repack) -----------
log "Applying retention (daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY yearly=$KEEP_YEARLY)"
restic forget \
    --tag nightly \
    --host nextbox \
    --keep-daily "$KEEP_DAILY" \
    --keep-weekly "$KEEP_WEEKLY" \
    --keep-monthly "$KEEP_MONTHLY" \
    --keep-yearly "$KEEP_YEARLY" \
    || log "WARNING: forget failed (snapshots still safe, retries next run)" >&2

# ---- Weekly maintenance: prune + integrity check ---------------------------
# GOGC=20 trades CPU for lower peak RAM while restic loads the index to prune.
if [ "$(date +%u)" = "$PRUNE_DOW" ]; then
    log "Weekly maintenance: prune (max repack ${PRUNE_MAX_REPACK}) + integrity check"
    GOGC=20 restic prune --max-repack-size "$PRUNE_MAX_REPACK" "${LIMIT_ARGS[@]}" \
        || log "WARNING: prune failed (retries next week)" >&2
    # Metadata-only check -- verifies repo structure without re-downloading data.
    restic check \
        || log "WARNING: repo check reported problems -- investigate" >&2
fi

log "Off-site backup finished"
