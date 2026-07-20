# nbbackup

A small Bash script that triggers a [NextBox](https://www.nitrokey.com/products/nextbox)
backup from cron on the NextBox itself, then polls the daemon until the backup
finishes.

It talks **only** to the local NextBox daemon over plain HTTP and only ever
*starts* a backup — it never restores — so it cannot overwrite live Nextcloud
data.

## How it works

The NextBox system daemon (`nextbox-daemon`) runs on the host and listens on
`0.0.0.0:18585`, but it authorizes callers purely by source IP: only requests
originating from its Docker network `172.18.238.0/24` are accepted. That
network (`nextbox-compose_default`) is where the Nextcloud stack runs, and the
daemon is meant to be called from inside it — a request sent from the host
itself collapses to a `127.0.0.1` source and is rejected with `not allowed`.

To satisfy that, the script issues its API calls with `docker exec` inside a
running container on that network (`nextbox-compose_app_1` by default). The
container reaches the daemon at the Docker gateway `172.18.238.1:18585`, so the
daemon sees an allowed `172.18.238.x` source. The JSON responses are parsed on
the host with `python3`.

The script:

1. Verifies the relay container is running (and that `docker` is usable).
2. `POST /backup/start` with the target `tar_path`.
3. Polls `GET /backup/status` every 30 s, logging progress.
4. Exits `0` on `completed`, non‑zero on `failed`, an unexpected `idle`
   status, or the 6‑hour timeout, clearing the daemon status on the way out.

## Requirements

- Runs **on the NextBox** (Raspberry Pi), as **root** or a user in the
  `docker` group (system cron runs as root, which is fine).
- `docker`, `curl` (present inside the relay container), and `python3` on the
  host.
- A running container on `nextbox-compose_default` — `nextbox-compose_app_1`
  by default. Change `CONTAINER` at the top of the script if yours differs.

## Usage

```bash
nextbox-backup.sh [TAR_PATH]
```

`TAR_PATH` defaults to `/media/extra-1/nc_backup` and **must** live under a
mounted NextBox backup device, or the daemon rejects it. Discover available
devices and existing backups with:

```bash
docker exec nextbox-compose_app_1 curl http://172.18.238.1:18585/backup
```

Run it once manually to confirm everything works (this starts a real backup):

```bash
sudo ./nextbox-backup.sh
```

You should see `Backup triggered successfully`, periodic `In progress: …`
lines, and finally `Backup completed successfully`.

## Install & schedule

Install the script and add a root cron entry to run every day at 04:00:

```bash
sudo install -m 0755 nextbox-backup.sh /usr/local/bin/nextbox-backup.sh
sudo crontab -e
```

```cron
0 4 * * * /usr/local/bin/nextbox-backup.sh >> /var/log/nextbox-backup-cron.log 2>&1
```

If a run ever logs `docker: command not found`, cron's minimal `PATH` is the
cause — add a `PATH=` line at the top of the crontab:

```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

## Off-site backup (pCloud)

The local backup above is a rolling mirror on a second disk in the same box — it
survives a disk failure, not a fire, theft, or ransomware that reaches both
disks. `nextbox-offsite.sh` adds the **off-site, encrypted, versioned** tier of
a 3‑2‑1 strategy by pushing the mirror to pCloud:

```
/srv (live) ──daemon rsync──▶ /media/extra-1/nc_backup ──restic via rclone──▶ pCloud
  internal disk               external disk (mirror)        encrypted · versioned · off-site
```

- **restic** does the encryption (client-side — pCloud only ever stores
  ciphertext), the snapshots + retention, and deduplication.
- **rclone** is *only* the transport: its native pcloud OAuth backend is how
  restic reaches pCloud (`rclone:pcloud:…`). No `pcloudcc`, no device-trust web
  flow, no unusable Crypto folder.
- It backs up the **mirror**, not live `/srv`, so it never touches Nextcloud.
- `nextbox-backup.sh` hands off to it automatically **after** a successful local
  run (so it never uploads a half-written mirror). Off-site failures are logged
  but don't fail the local backup — the upload is resumable and retries nightly.

### One-time setup

**1. Install rclone + restic on the Pi:**

```bash
curl https://rclone.org/install.sh | sudo bash        # recent rclone
sudo apt-get install -y restic && sudo restic self-update   # recent restic
```

**2. Authorise pCloud — headless "remote setup" flow.** The Pi has no browser,
so build the remote on the Pi but do the one browser step on your Mac (see
<https://rclone.org/remote_setup/>). Build it in **root's** config, since cron
runs the backup as root:

```bash
# On the Pi:
sudo rclone config
#   n → name: pcloud → storage: pcloud → blank client_id/secret
#   → Edit advanced config? No
#   → Use web browser to automatically authenticate? No   ← the headless choice
# rclone now prints a command to run on a machine that HAS a browser:

# On the Mac:
rclone authorize "pcloud"      # opens a browser; log in + authorise pCloud
#   → prints a token blob; paste it back into the waiting prompt on the Pi

# Back on the Pi: finish the wizard (y to keep), then verify:
sudo rclone lsd pcloud:        # should list your pCloud root
```

> **Region gotcha (EU accounts).** rclone defaults to the US endpoint
> (`api.pcloud.com`). If `sudo rclone lsd pcloud:` fails with
> `Invalid 'access_token' provided. (2094)`, your account is on the **EU**
> datacentre and you must point rclone at it. The token is fine — only the
> hostname is wrong. **Edit the config file directly** (do *not* use
> `rclone config update`, which re-triggers the browser OAuth flow): add a
> `hostname = eapi.pcloud.com` line under the `[pcloud]` block in
> `/root/.config/rclone/rclone.conf`, then re-run `sudo rclone lsd pcloud:`.

**3. Create the repo password — and save it in your password manager.**
⚠️ **Lose this password and the backup is permanently unrecoverable.** There is
no recovery; restic is zero-knowledge by design.

```bash
sudo mkdir -p /root/.config/restic
openssl rand -base64 32 | sudo tee /root/.config/restic/password
sudo chmod 600 /root/.config/restic/password
# → copy that printed string into your password manager NOW
```

**4. Initialise the restic repo (one time):**

```bash
sudo RESTIC_REPOSITORY=rclone:pcloud:nextbox-restic \
     RESTIC_PASSWORD_FILE=/root/.config/restic/password \
     restic init
```

**5. Install the script:**

```bash
sudo install -m 0755 nextbox-offsite.sh /usr/local/bin/nextbox-offsite.sh
```

That's it — because `nextbox-backup.sh` auto-detects `/usr/local/bin/nextbox-offsite.sh`,
the nightly cron job now chains into the off-site push with no further wiring.

### First seed

The initial upload is the whole dataset over a slow link — **days, possibly
weeks**. It's resumable (restic dedups, so re-runs skip what's already up), but
kick it off by hand in a detached session rather than waiting for cron:

```bash
sudo screen -S seed          # or tmux
sudo /usr/local/bin/nextbox-offsite.sh
# detach: Ctrl-a d   (reattach: sudo screen -r seed)
```

### Tuning

Override defaults in `/etc/default/nextbox-offsite` (sourced by the script):

```sh
LIMIT_UPLOAD=4096        # upload cap in KiB/s (0 = unlimited); raise once seeded
KEEP_DAILY=7             # retention: forget runs nightly (cheap, no repack)
KEEP_WEEKLY=5
KEEP_MONTHLY=12
KEEP_YEARLY=3
PRUNE_DOW=7              # prune + integrity check run only on this weekday (Sun)
PRUNE_MAX_REPACK=5G      # cap bytes repacked per prune (prune re-uploads packs)
RESTIC_COMPRESSION=auto  # "max" trades Pi CPU for fewer bytes over the uplink
```

`forget` (delete old snapshots — metadata only, cheap) runs every night; `prune`
(actually reclaim space, which repacks and re-uploads over the slow link) is
gated to once a week to avoid thrashing the uplink.

### Restoring

```bash
sudo RESTIC_REPOSITORY=rclone:pcloud:nextbox-restic \
     RESTIC_PASSWORD_FILE=/root/.config/restic/password restic snapshots
# restore the latest snapshot into a scratch dir (never straight onto live data):
sudo … restic restore latest --target /media/extra-1/restore-test
```

## Notes & caveats

- **No version history.** The default target is a single fixed directory that
  the daemon syncs with `rsync --delete` on every run — a rolling mirror. It
  protects against disk failure, not against corruption or ransomware
  propagating into the backup. For point‑in‑time recovery, use dated
  `TAR_PATH`s (a separate scheme, not built in here).
- **Long silent gaps are normal.** Before each directory, the daemon runs a
  blocking `rsync --dry-run --stats` to count files; during that scan it emits
  no status update, so the poller keeps showing the previous state
  (`finished` / `100`) for minutes on a large data directory. It is counting,
  not stuck.
- **Plain HTTP, no TLS.** The daemon serves HTTP on `18585`, so there is no
  certificate involved; the script uses `http://` and does not need
  `--insecure`.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
