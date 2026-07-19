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

`TAR_PATH` defaults to `/media/NextBoxHardDisk/scheduled_backup` and **must**
live under a mounted NextBox backup device, or the daemon rejects it. Discover
available devices and existing backups with:

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
