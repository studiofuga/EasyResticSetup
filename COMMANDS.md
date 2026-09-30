# Command reference

Every command of the restic backup system, Windows and Linux together. One entry per
command, with both spellings side by side, what it reads, what it changes, and what it
costs to run.

`RUNBOOK.md` is the other half: it answers "how do I do X" in prose and carries the
history of why things are the way they are. This file answers "what exactly does this
command take".

---

## Contents

- [The scripts](#the-scripts)
- [Where everything lives](#where-everything-lives)
- [How to read the two spellings](#how-to-read-the-two-spellings)
- [Cheat sheet](#cheat-sheet)
- [`restic-ctl` — day to day](#restic-ctl--day-to-day)
  - [status](#restic-ctl-status) · [snapshots](#restic-ctl-snapshots) ·
    [run](#restic-ctl-run) · [check](#restic-ctl-check) ·
    [schedule](#restic-ctl-schedule) · [history](#restic-ctl-history) ·
    [log](#restic-ctl-log) · [config](#restic-ctl-config) ·
    [publish](#restic-ctl-publish) · [unpublish](#restic-ctl-unpublish) ·
    [help](#restic-ctl-help)
  - [exec](#restic-ctl-exec) · [forget](#restic-ctl-forget) ·
    [restore](#restic-ctl-restore) · [unlock](#restic-ctl-unlock) ·
    [ls](#restic-ctl-ls) · [find](#restic-ctl-find)
- [The installer](#the-installer)
- [`restic-backup` — the scheduled job itself](#restic-backup--the-scheduled-job-itself)
- [`nas-provision-<user>.sh` — the NAS side](#nas-provision-user-sh--the-nas-side)
- [`nas-fleet-status.sh` — the whole fleet from the NAS](#nas-fleet-statussh--the-whole-fleet-from-the-nas)
- [`config.json`](#configjson)
- [Exit codes](#exit-codes)
- [Retired options](#retired-options)
- [Where Windows and Linux differ](#where-windows-and-linux-differ)

---

## The scripts

| Script | Runs on | What it is for |
|---|---|---|
| `Setup-ResticBackup.ps1` | the Windows client | install and repair the whole setup, in nine idempotent steps |
| `setup-restic-backup.sh` | the Linux client | the same nine steps on Linux |
| `restic-ctl.ps1` (+ `restic-ctl.cmd`) | the Windows client | everything after installation: status, runs, checks, schedule, restic wrapper |
| `restic-ctl.sh` | the Linux client | the same, on Linux |
| `restic-backup.ps1` / `restic-backup.sh` | the client | **generated.** The backup itself, run by the scheduler. Not edited by hand |
| `nas-provision-<user>.sh` | the **NAS**, as root | **generated.** Creates the NAS account's home, ACL and `authorized_keys` |
| `nas-fleet-status.sh` | the **NAS**, as an admin | how fresh every machine's backup is, without any repository password |

Two of those are generated and are overwritten on the next install or update: the backup
script and the NAS provisioning script. Everything you want to change is in
`config.json`, in `excludes.txt`, or in the installer that generates them.

## Where everything lives

| | Windows | Linux |
|---|---|---|
| Configuration and credentials | `C:\ProgramData\restic` | `/etc/restic` |
| Installed tools | `C:\Program Files\restic-backup` | `/usr/local/lib/restic-backup` |
| On `PATH` as | `restic-ctl` (via `restic-ctl.cmd`) | `/usr/local/bin/restic-ctl` |
| The generated backup script | `C:\ProgramData\restic\restic-backup.ps1` | `/usr/local/bin/restic-backup.sh` |
| Log | `…\restic\logs\restic-backup.log` | `/var/log/restic-backup.log` |
| Scheduler | Task Scheduler task `restic-backup`, running as `SYSTEM` | `restic-backup.service` + `restic-backup.timer` |
| Who may read the credentials | `SYSTEM` and `Administrators` only | `root` only |

Under the configuration directory, on both: `config.json`, `password`,
`excludes.txt`, `ssh/config`, `ssh/id_ed25519`, `ssh/known_hosts`, `progress.json`,
`last-run.json`, `history.jsonl`, `cache/`.

## How to read the two spellings

Windows uses PowerShell parameters (`-Deep`, `-Count 30`), Linux uses long options
(`--deep`, `--count 30`). The names match one for one except where the platform makes
one meaningless; those cases are called out. Subcommands, defaults and output are the
same.

Everything except help needs elevation: an **administrator** PowerShell on Windows,
`sudo` on Linux. That is not incidental — the SSH key and the repository password are
readable only by `SYSTEM`/`Administrators` and by `root` respectively, and a backup you
can run as yourself would be a backup anyone on the machine could read the keys of.

Throughout, `restic-ctl` means the installed copy on `PATH`. From a checkout you can
also run `.\restic-ctl.ps1` or `./restic-ctl.sh` directly.

## Cheat sheet

| Question | Windows | Linux |
|---|---|---|
| Is the backup healthy? | `restic-ctl status` | `sudo restic-ctl status` |
| What is in the repository? | `restic-ctl snapshots` | `sudo restic-ctl snapshots` |
| Back up now, properly | `restic-ctl run` | `sudo restic-ctl run` |
| Did anything fail lately? | `restic-ctl history` | `sudo restic-ctl history` |
| Is the repository sound? | `restic-ctl check` | `sudo restic-ctl check` |
| Is the data itself sound? | `restic-ctl check -Data` | `sudo restic-ctl check --data` |
| When does it run? | `restic-ctl schedule` | `sudo restic-ctl schedule` |
| Move that time | `restic-ctl schedule 03:30` | `sudo restic-ctl schedule '*-*-* 03:30'` |
| Prove a restore works, no disk | `restic-ctl exec dump latest "C:/…/file" > NUL` | `sudo restic-ctl exec dump latest /…/file > /dev/null` |
| Delete a snapshot | `restic-ctl forget <id> --dry-run` first | same |
| Any restic command | `restic-ctl exec <args>` | `sudo restic-ctl exec <args>` |
| What would Home Assistant get? | `restic-ctl publish --dry-run` | `sudo restic-ctl publish --dry-run` |
| Send it to Home Assistant now | `restic-ctl publish` | `sudo restic-ctl publish` |
| Remove the machine from Home Assistant | `restic-ctl unpublish` | `sudo restic-ctl unpublish` |
| Install or repair | `.\Setup-ResticBackup.ps1` | `sudo ./setup-restic-backup.sh` |
| Update to newer scripts | `.\Setup-ResticBackup.ps1 -Update` | `sudo ./setup-restic-backup.sh --update` |
| Whole fleet, from the NAS | `sudo sh nas-fleet-status.sh` (on the NAS) | same |

---

# `restic-ctl` — day to day

```
restic-ctl <command> [options]
restic-ctl help [<command>]
```

With no command it runs `status`. `status`, `snapshots` and `history` read local files
and repository metadata only, so they are instant and safe to run while a backup is in
progress.

**Options, all commands**

| Windows | Linux | Applies to | Meaning |
|---|---|---|---|
| `-Base <dir>` | `--base <dir>` | all | configuration directory (default as in the table above) |
| `-Help` | `-h`, `--help` | all | the command index; after a command, that command's detail |
| `-Deep` | `--deep` | status, snapshots | also run a structural `restic check` |
| `-Data` | `--data` | check | re-read actual data blobs |
| `-Subset <f>` | `--subset <f>` | check | how much data to re-read, default `1/12`; implies `-Data` |
| `-Count <n>` | `--count <n>` | history, log | how many entries, default 15 |
| `-Follow` | `--follow` | log | keep watching |
| `-NoWait` | `--no-wait` | run | start and return instead of following |
| `-Yes` | `--yes` | forget | skip the confirmation prompt |
| `-Target <dir>` | `--target <dir>` | restore | where to restore to (required) |
| `-TimeLimitHours <n>` | — | schedule | kill-after-N-hours, Windows only |
| `-WakeToRun` / `-NoWakeToRun` | — | schedule | wake the machine to run, Windows only |
| — | `--retry <spec>` | schedule | the second same-day `OnCalendar`, Linux only |
| `-TaskName <name>` | — | all | the scheduled task's name, default `restic-backup` |

Anything not in that list is passed through to restic by `exec`, `forget`, `restore`,
`ls` and `find`, so restic's own options work unchanged: `--dry-run`, `--long`,
`--include`, `--json`.

---

### `restic-ctl status`

```
restic-ctl status [-Deep]
sudo restic-ctl status [--deep]
```

The one command to run when you want to know whether the backup is working. It reads
only local state, so it costs nothing and cannot disturb a running backup.

What it reports:

| Field | Meaning |
|---|---|
| **State** | `idle`, or `running` — and where that came from: the scheduler, a bare `restic` process, or only a progress file that is still fresh (shown as `maybe`) |
| **Progress** | while running: files and bytes done, from `progress.json`. The backup script writes it from `restic --json`, which is the only way to see progress from a scheduled run — it has no terminal and so no progress bar |
| **Last run** | result, when, how long, what changed |
| **Scheduler** | the task's or timer's state, last result, next run |
| **Recent failures** | counted from `history.jsonl`. This matters: a failed backup leaves **no trace in the repository**, so `restic snapshots` looks entirely normal after one |
| **Credentials** | Windows: that the SSH key is owned by `SYSTEM`/`Administrators` and that nobody else is granted access — the two independent causes of `UNPROTECTED PRIVATE KEY FILE`. Linux: root-owned and `600` |

`-Deep` / `--deep` adds a structural `restic check`. That contacts the NAS and takes a
minute or two on a large repository.

### `restic-ctl snapshots`

```
restic-ctl snapshots [-Deep]
sudo restic-ctl snapshots [--deep]
```

The snapshot list with tags and paths, the **age of the newest** one, and repository
totals from `restic stats`. Metadata only; nothing file-sized is downloaded.

Age is the number to look at. A repository can be perfectly healthy and useless because
the newest snapshot is three weeks old — which is exactly what a scheduler that has been
failing quietly looks like.

### `restic-ctl run`

```
restic-ctl run [-NoWait]
sudo restic-ctl run [--no-wait]
```

Starts the backup **through the scheduler**, and this is the whole point of the command.
On Windows it starts the scheduled task, which runs as `SYSTEM`: the `SYSTEM`
environment, the `SYSTEM` view of network drives, the credentials `SYSTEM` can read. On
Linux it starts `restic-backup.service`, with its `Nice`, its `IOSchedulingClass` and its
`ConditionACPower=true`.

A backup you launch by hand, as yourself, can succeed while the scheduled one fails —
and then you have tested nothing.

By default it follows the run, refreshing from `progress.json` until it finishes.
`Ctrl-C` stops watching, **not** the backup. `-NoWait` / `--no-wait` starts it and
returns.

If a backup is already running it refuses and points at `status`.

On Linux, note `ConditionACPower`: on battery the service does not start, and systemd
records that as a skipped start rather than a failure. That is deliberate.

### `restic-ctl check`

```
restic-ctl check [-Data] [-Subset <fraction>]
sudo restic-ctl check [--data] [--subset <fraction>]
```

Three levels:

| Level | What it verifies | Cost |
|---|---|---|
| default | structure: every index, tree and pack is referenced and reachable | metadata only, minutes |
| `-Data -Subset 1/12` | re-reads a twelfth of the data blobs and checks their hashes | **bandwidth, not disk** — nothing is written locally |
| `-Data -Subset 100%` | re-reads everything | hundreds of GB over SFTP on this repository |

`1/12` is the default because twelve monthly runs cover the whole repository, which is
how to get full verification on a link that cannot afford downloading it all at once.
`-Subset` accepts a fraction (`1/12`) or a percentage (`5%`) and implies `-Data`.

What `check` does **not** tell you is whether a restore works. See
[`restore`](#restic-ctl-restore).

### `restic-ctl schedule`

```
restic-ctl schedule                                  show
restic-ctl schedule <HH:mm>                          move the daily start time
restic-ctl schedule [<HH:mm>] -TimeLimitHours <n>
restic-ctl schedule [<HH:mm>] -WakeToRun | -NoWakeToRun

sudo restic-ctl schedule                             show
sudo restic-ctl schedule <spec>                      change the main OnCalendar entry
sudo restic-ctl schedule [<spec>] --retry <spec>
```

With no argument it shows **both sides** and says whether they agree: the intent stored
in `config.json`, and what the scheduler actually has registered. That is the point of
the report — the two drifting apart is a real failure mode, and the previous design made
it easy to cause.

With an argument it writes `config.json` first, then re-registers by calling **step 8 of
the installed installer**, then re-reads both sides to confirm. The registration lives
in exactly one place on purpose; two pieces of code writing the same task or unit is how
they end up disagreeing.

**Windows**

`<HH:mm>` on a 24-hour clock. `3:30` is accepted and stored as `03:30`; anything that is
not a time is refused before anything is written.

- `-TimeLimitHours <n>` — Task Scheduler **kills** the run at this limit. Default 20. A
  first backup with no parent snapshot has to read and hash everything: on a 1 TB profile
  that took 10h25m, so the 6 hours that looked generous would have terminated it halfway.
- `-WakeToRun` / `-NoWakeToRun` — wake the machine at the start time. Off by default:
  waking a laptop on battery only to skip the backup achieves nothing. On a desktop that
  sleeps, turn it on.

**Linux**

`<spec>` is a systemd calendar expression, validated with `systemd-analyze calendar`
before anything is written — a bad expression in the unit means a timer that silently
never fires.

| Spec | Means |
|---|---|
| `daily` | midnight, not 03:00 |
| `'*-*-* 03:30'` | every day at 03:30 |
| `'*-*-* 03,15:30'` | twice a day |
| `Mon..Fri 20:00` | weekdays only |
| `03:30` | accepted as shorthand for `'*-*-* 03:30'` |

There are **two** `OnCalendar` entries. The second is the retry: if the first run was
interrupted — a suspend, the machine on battery, the NAS unreachable — this one picks it
up the same day instead of waiting until tomorrow. When the first run succeeded the
second is a fast incremental and costs almost nothing. `--retry` sets it.

**Not settable here, deliberately.** The battery behaviour and the retry policy are not
knobs: Windows does not start on battery, stops if unplugged, and retries three times 30
minutes apart; Linux has `ConditionACPower=true`, `Persistent=true` and
`RandomizedDelaySec=15m`. Those are the laptop-friendly defaults and the retry is what
turns a backup interrupted by a suspend into a completed one.

If the installer is not in the tools directory, nothing is changed and the command prints
the line to run instead.

### `restic-ctl history`

```
restic-ctl history [-Count <n>]
sudo restic-ctl history [--count <n>]
```

A table of recent runs from `history.jsonl`, appended by the backup script at the end of
every run: start, duration, result, new and changed files, bytes added, snapshot id when
there is one.

This file exists because **the repository holds no record of a failed backup**. If the
run died there is no snapshot, and nothing in restic's own output will tell you it ever
tried.

### `restic-ctl log`

```
restic-ctl log [-Count <n>] [-Follow]
sudo restic-ctl log [--count <n>] [--follow]
```

The tail of the backup log. `-Follow` / `--follow` keeps watching.

For a backup in progress, `status` is usually the better view: the log records what
happened at each stage, `progress.json` carries the live counters. On Linux,
`journalctl -u restic-backup.service` is the other half of the picture.

### `restic-ctl config`

```
restic-ctl config
sudo restic-ctl config
```

Where the configuration lives, the NAS account and port, the tools directory, the
composed repository string, the SSH config, the backup paths, the retention policy; then
every file the system uses with its size and age; then the active exclude patterns.

The repository string is **composed** from `hostAlias` and `repoPath` every time it is
needed and never stored. Two copies of the same string is one copy too many.

To change anything here, edit `config.json` and re-run the installer from step 3 so the
generated files follow. The exception is the schedule, which has its own command.

### `restic-ctl publish`

```
restic-ctl publish [--dry-run]          (-DryRun works too)
sudo restic-ctl publish [--dry-run]
```

Sends this machine's backup state to Home Assistant now: the same two messages the
backup sends at the end of every run, QoS 1, retained, to the broker in the
`homeAssistant` section of `config.json`:

- `homeassistant/device/restic/<id>/config`, MQTT discovery: Home Assistant creates the
  device and its entities from it, so nothing is configured there for each machine;
- `restic/<box>`, the state: `last-run.json` plus `box` and `publishedAt`.

Use it to check the broker settings without waiting for a backup, or to put a
machine back after its retained messages were cleared. What the entities are, and
the broker ACL they need, is in `HOME-ASSISTANT.md`.

`--dry-run` prints what would be sent and sends nothing: broker, login (only whether a
password is stored, never the password), client id, both topics with their sizes, and
both payloads. It does not contact the broker, writes nothing to the log, and also
works before a broker is configured.

```
  Home Assistant messages (dry run, nothing sent)
  -----------------------------------------------
  Broker            <mqtt-user>@<broker>:1883
  Login             password stored
  Client id         restic-<machine>
  Delivery          QoS 1, retained
  Discovery         homeassistant/device/restic/restic-<machine>/config, 1681 bytes
  Topic             restic/restic-<machine>, 358 bytes

    Discovery payload:
    {
      "device": { "identifiers": ["restic-<machine>"], "name": "restic-<machine>", ... },
      "state_topic": "restic/restic-<machine>",
      "components": { "outcome": {...}, "last_run": {...}, ... }
    }

    State payload:
    {
      "startedAt": "...",
      "outcome": "ok",
      ...
      "box": "restic-<machine>",
      "publishedAt": "..."
    }
```

The work is done by the installed backup script (`--publish`, `--publish --dry-run`), not
by a second copy of the MQTT code, so the preview is by construction what a scheduled run
sends. On a machine whose backup script predates the command, or predates discovery, it
says so and exits 1: bring it up to date with the installer's `--update` / `-Update`.

Exit codes: 0 sent or previewed, 1 the broker did not accept it, 2 Home Assistant is not
configured.

### `restic-ctl unpublish`

```
restic-ctl unpublish [--dry-run]        (-DryRun works too)
sudo restic-ctl unpublish [--dry-run]
```

Removes this machine from Home Assistant: an empty retained message on each of the two
topics `publish` uses. Home Assistant deletes the device and its entities, and the
broker forgets the last state. `--dry-run` prints the two topics and sends nothing.

The next backup announces the machine again, so to retire one, stop its schedule first:

```
Disable-ScheduledTask -TaskName restic-backup ; restic-ctl unpublish
sudo systemctl disable --now restic-backup.timer && sudo restic-ctl unpublish
```

Exit codes as for `publish`.

### `restic-ctl help`

```
restic-ctl help              the command index
restic-ctl help <command>    that command's detail
restic-ctl <command> --help  the same
```

Works without elevation and on a machine with no backup configured yet — which is when
you are most likely to want it.

---

## Passthrough commands

These are restic itself, with this machine's repository, password file, cache directory
and `sftp.command` already filled in. The point is never to retype them.

### `restic-ctl exec`

```
restic-ctl exec <restic arguments>...
sudo restic-ctl exec <restic arguments>...
```

```
restic-ctl exec snapshots --json
restic-ctl exec stats latest
restic-ctl exec diff 4f2a9c1b b9dd1b6d
restic-ctl exec dump latest "C:/Users/me/notes.txt" > NUL     # Windows
sudo restic-ctl exec dump latest /home/me/notes.txt > /dev/null
sudo restic-ctl exec mount /mnt/restic                        # Linux only
```

`dump` is worth knowing: it streams a file out of the repository and verifies it end to
end **without writing anything to disk**. It is how to prove a restore works on a machine
with no room for one.

No confirmation and no guard rails here — it is restic. Destructive operations have their
own wrappers for exactly that reason.

### `restic-ctl forget`

```
restic-ctl forget <snapshot-id>... [--dry-run] [-Yes]
sudo restic-ctl forget <snapshot-id>... [--dry-run] [--yes]
```

Removes those snapshots, then prunes. Pruning is what actually frees space on the NAS;
forgetting alone only unlinks the snapshot.

```
restic-ctl forget b9dd1b6d --dry-run     say what would go, change nothing
restic-ctl forget b9dd1b6d               show it, then ask before doing it
restic-ctl forget b9dd1b6d -Yes          no prompt
```

Always `--dry-run` first. Data shared with other snapshots is kept, so the space freed is
often far less than the snapshot's apparent size — and occasionally far more than you
expected. Not undoable once prune has run.

The scheduled backup already applies the retention policy from `config.json` after every
successful run; this command is for a particular snapshot you want gone now.

### `restic-ctl restore`

```
restic-ctl restore [<snapshot-id>] -Target <folder>
sudo restic-ctl restore [<snapshot-id>] --target <dir>
```

Snapshot id defaults to `latest`. The target is required, must be empty or absent, and
must not sit inside a path that is itself being backed up.

A full restore needs as much free space as the snapshot holds. Three ways to verify
without that space, in increasing fidelity:

```
restic-ctl exec dump latest "C:/Users/me/notes.txt" > NUL
    one file, streamed and hash-checked. Zero disk.

restic-ctl restore latest -Target D:\restore-test --include "C:/Users/me/Documents"
    a real restore of one subtree: a genuine end-to-end test at an affordable size.

sudo restic-ctl exec mount /mnt/restic
    Linux only, and the best of the three: the whole repository as a read-only
    filesystem, every snapshot browsable, nothing copied. Needs FUSE. Ctrl-C unmounts.
```

Paths inside a Windows snapshot keep the drive letter and use forward slashes:
`C:/Users/me/Documents`. Get the exact spelling from `restic-ctl ls latest`.

### `restic-ctl unlock`

```
restic-ctl unlock
sudo restic-ctl unlock
```

restic locks the repository while writing. A run killed mid-flight — a suspend, a time
limit, a power cut, an OOM kill — can leave that lock behind, and the next backup fails
with `repository is already locked`.

Only run this when no backup is actually running. Check `status` first: removing the lock
out from under a live run is how a repository gets damaged.

### `restic-ctl ls`

```
restic-ctl ls [<snapshot-id>] [<path>] [restic options]
sudo restic-ctl ls [<snapshot-id>] [<path>] [restic options]
```

Defaults to `latest`. The way to find the exact spelling of a path to hand to `restore`
or `dump`.

```
restic-ctl ls latest
restic-ctl ls latest "C:/Users/me/Documents"
restic-ctl ls b9dd1b6d --long
```

### `restic-ctl find`

```
restic-ctl find <pattern> [restic options]
sudo restic-ctl find <pattern> [restic options]
```

Searches every snapshot, so slower than `ls`. Patterns are globs; quote them so the shell
does not expand them first.

```
restic-ctl find "*.kdbx"
sudo restic-ctl find '**/Documents/tax-2025*'
```

The answer to "did that file ever get backed up, and when did it last change".

---

# The installer

```
.\Setup-ResticBackup.ps1 [-NasHost <host>] [options]      elevated PowerShell
sudo ./setup-restic-backup.sh [--nas-host HOST] [options]
```

Nine idempotent steps. Re-running is safe: every step detects what is already in place
and skips or repairs it. After the first run **no parameters are needed** — they come
from `config.json`.

| Step | What it does |
|---|---|
| 1 | prerequisites: elevation, `restic`, `ssh`, `ssh-keygen`, `ssh-keyscan`, `sftp` |
| 2 | create the configuration directory, lock it down, and **install the tools** into the tools directory so a setup run from a USB stick does not leave the machine depending on the stick |
| 3 | write `config.json`, `ssh/config`, `excludes.txt` and the backup script |
| 4 | generate the SSH key, the repository password, and `nas-provision-<user>.sh` |
| 5 | trust the NAS host key — the fingerprint is printed for you to confirm |
| 6 | **verify authentication and write access** — the one manual gate |
| 7 | initialise the repository, skipped if it exists |
| 8 | register the scheduled task / install and enable the systemd units |
| 9 | print the summary and the first-backup commands |

Step 6 stops until the public key is in the NAS account's `authorized_keys`. It prints
exactly what to run on the NAS; then you re-run the installer and it continues.

### What to pass on a first run

| Windows | Linux | Default | Notes |
|---|---|---|---|
| `-NasHost <host>` | `--nas-host HOST` | none — **asked for** | nothing site-specific is baked into these scripts. On a laptop prefer the Tailscale name so the backup also works away from the LAN |
| `-NasUser <user>` | `--nas-user USER` | `restic-<hostname>` | one dedicated Synology account per machine |
| `-Port <n>` | `--nas-port PORT` | 22 | |
| `-RepoPath <path>` | `--repo-path PATH` | `home/restic-repo` | see the warning below |
| `-BackupPath <p>[,<p>]` | `--backup-paths "A B"` | Windows: the user profile · Linux: `/home /etc` | |
| `-HostAlias <name>` | `--host-alias NAME` | `nas-restic` | the `Host` entry in `ssh/config`, and the first half of the repository string |

### Home Assistant reporting (optional, any run)

After every backup the outcome is published over MQTT, **retained**, to the broker Home
Assistant uses, together with an MQTT discovery message, so the machine appears in Home
Assistant as a device without any configuration there. Off until an HA host is given;
stored in `config.json` like everything else, so it is typed once. The Home Assistant and
broker side, ACL included, is in `HOME-ASSISTANT.md`.

| Windows | Linux | Default | Notes |
|---|---|---|---|
| `-HaHost <host>` | `--ha-host HOST` | none — off | MQTT broker address. `''` turns reporting off again |
| `-HaPort <n>` | `--ha-port PORT` | 1883 | |
| `-HaUser <user>` | `--ha-user USER` | none | MQTT account for this machine |
| `-HaPasswordFile <f>` | `--ha-password-file FILE` | — | read the MQTT password from the file once and store it as `mqtt-password` beside the repository password. Without it an interactive run asks with hidden input, so the password never appears on a command line |
| `-HaBox <name>` | `--ha-box NAME` | the NAS user | this machine's name in Home Assistant |
| `-HaTopic <topic>` | `--ha-topic TOPIC` | `restic/<box>` | state topic. No leading slash: MQTT would treat it as an empty first level |

Step 3 sends a test message and reports the broker's answer, so switching a machine that
is already set up is a single step:

```
.\Setup-ResticBackup.ps1 -Only 3 -HaHost <broker> -HaUser <mqtt-user>
sudo ./setup-restic-backup.sh --only 3 --ha-host <broker> --ha-user <mqtt-user>
```

Two messages go out: the discovery message on `homeassistant/device/restic/<id>/config`, then
the state on the topic above, which is the content of `last-run.json` plus `box` and
`publishedAt`. On a machine that has never run a backup, `outcome` is `never`. Both are
sent after every real run — success, failure, or failed prune — and never after a dry
run. A broker that is down or
refuses the login is logged (`ha: publish FAILED: …`) and changes nothing about the
backup's own result or exit code.

```json
{"startedAt": "...", "finishedAt": "...", "durationSec": 812, "outcome": "ok",
 "exitCode": 0, "host": "...", "runAs": "root", "snapshotId": "...",
 "filesNew": 3, "filesChanged": 12, "dataAddedBytes": 1234567,
 "filesProcessed": 2868685, "bytesProcessed": 363889000000,
 "box": "restic-<machine>", "publishedAt": "2026-09-30T04:13:27+02:00"}
```

`outcome` is one of `ok`, `warnings`, `failed`, `prune-failed`, `never`.

> **`home` vs `homes`.** `home` (singular) is DSM's per-user alias for the logged-in
> account's own home and needs no permission on any shared folder. `homes` (plural) is
> the shared folder holding everyone's homes, and reaching a repository through
> `homes/<user>/…` needs a share permission a backup-only account normally does not
> have — it fails with a bare `permission denied` even when the home's own ACL is
> perfect. This distinction cost an afternoon of chasing ACLs. Do not change it without
> a reason.

### Options

| Windows | Linux | Meaning |
|---|---|---|
| `-From <n>` | `--from N` | start at step n |
| `-Only <n>` | `--only N` | run just step n. This is how `restic-ctl schedule` applies a change: it writes `config.json`, then calls step 8 |
| `-Update` | `--update` | install the tools, regenerate the generated files, re-verify: the same as `-From 2` plus the downgrade guard below |
| `-Force` | `--force` | let `-Update` install an older version on purpose |
| `-ForceExcludes` | `--force-excludes` | step 3 leaves an existing `excludes.txt` alone, because it is meant to be tuned by hand. This replaces it with the current template, keeping the old one as `excludes.txt.bak` |
| `-AcceptChanges` | `--accept-changes` | do not ask for confirmation when a parameter would change this machine's NAS identity |
| `-SkipTask` | `--skip-timer` | do everything except registering the scheduler |
| `-NoPath` | — | do not add the tools directory to the machine `PATH` |
| `-NasSetup` | `--nas-setup` | only write `nas-provision-<user>.sh` and print how to run it, then exit. Nothing local is changed |
| `-Base <dir>` | `--base DIR` | configuration directory |
| `-ToolsDir <dir>` | `--tools-dir DIR` | tools directory |
| `-TaskName <name>` | — | scheduled task name, default `restic-backup` |
| `-Help` | `-h`, `--help` | the full usage |

`Get-Help .\Setup-ResticBackup.ps1 -Full` also works on Windows; `-Help` prints the same
reference in the same shape as the Linux `--help`.

### Updating a machine

```
.\Setup-ResticBackup.ps1 -Update
sudo ./setup-restic-backup.sh --update
```

**Run the copy you just brought over, not the installed one.** The installed copy sits on
a known path and is the easy one to type, and running it would reinstall the older
version — which is the mistake the guard exists to catch.

Each script carries a `SCRIPT_VERSION` stamp and compares itself to the installed copy by
stamp **and** by hash:

| Verdict | What happens |
|---|---|
| nothing installed | proceeds |
| same version | proceeds |
| the copy you ran is newer | proceeds, printing `old -> new` |
| **the copy you ran is older** | **stops, exit 3** |
| same version, different content | warns and proceeds |

The hash is why the last row exists: a version I forgot to bump would otherwise hide a
real difference. To go back on purpose, `-Force` / `--force`.

> If you edit a script yourself, bump its `SCRIPT_VERSION`. Otherwise two different
> contents carry the same version and the guard falls back to the weakest verdict — the
> one that warns without stopping.

---

# `restic-backup` — the scheduled job itself

`C:\ProgramData\restic\restic-backup.ps1` on Windows,
`/usr/local/bin/restic-backup.sh` on Linux. Run by the scheduler; you normally use
`restic-ctl run` instead, which goes through the scheduler and therefore tests the thing
that actually matters.

```
.\restic-backup.ps1            normal run (what the task does)
.\restic-backup.ps1 -DryRun    list what would be backed up, no upload, no prune
.\restic-backup.ps1 -Init      one-time: create the repository
.\restic-backup.ps1 -Help

.\restic-backup.ps1 -Publish   re-send last-run.json to Home Assistant, no backup
.\restic-backup.ps1 -Publish -DryRun   print the topic and payload, send nothing
.\restic-backup.ps1 -Unpublish   remove this machine from Home Assistant
.\restic-backup.ps1 -Unpublish -DryRun

restic-backup.sh               normal run (what the service does)
restic-backup.sh --dry-run
restic-backup.sh --init
restic-backup.sh --publish
restic-backup.sh --publish --dry-run
restic-backup.sh --unpublish
restic-backup.sh --unpublish --dry-run
restic-backup.sh --help
```

`-Publish` / `--publish` sends the discovery and state messages; `-Unpublish` /
`--unpublish` empties both. Each exits 0 when the broker confirmed the messages, 1 when
it did not (the reason is printed and logged), 2 when Home Assistant is not configured.
With `-DryRun` / `--dry-run` after it, it prints the messages instead and always exits 0
unless they cannot be built. `restic-ctl publish` and `restic-ctl unpublish` are the
friendlier way in.

It reads everything from `config.json` and writes the log, `progress.json`,
`last-run.json` and `history.jsonl`. On Windows it uses `--use-fs-snapshot` (VSS), which
is why it needs to run elevated. On both it applies the retention policy after a
successful run, and asks the OS not to sleep while it works — Windows through the Power
Request API, Linux through `systemd-inhibit --what=idle`.

**Edits here are overwritten by the next update.** Change `config.json`, or the installer
that generates this file.

---

# `nas-provision-<user>.sh` — the NAS side

Generated by step 4, one per machine, named after that machine's NAS account. Runs **on
the NAS, as root**, and is the only thing that touches the NAS:

- creates the account's home under `/volume1/homes/<user>` if DSM has not
- sets ownership and mode `711`
- adds the Synology ACL entry the account needs, and re-adds it after
  `synoacltool -enforce-inherit`, which removes explicit entries
- installs the machine's public key into `authorized_keys` with mode `600`

The installer prints how to copy and run it. It refuses to be the wrong one: if scripts
for other machines are present it lists them, because running one machine's provisioning
script for another is a mistake that has happened.

```
sudo sh /tmp/nas-provision-restic-<machine>.sh && rm /tmp/nas-provision-restic-<machine>.sh
```

---

# `nas-fleet-status.sh` — the whole fleet from the NAS

```
sudo sh nas-fleet-status.sh [options]
```

Runs on the NAS as an admin account. Finds every restic repository under the per-user
homes and reports the age of each one's newest snapshot, so one command answers "is
anything not backing up" for all machines at once.

It holds **no repository passwords and needs none**: the age of a snapshot is the mtime of
the newest file under the repository's `snapshots/` directory, which is readable without
being able to decrypt anything. So it can run from an account that cannot read a single
backed-up byte.

| Option | Default | Meaning |
|---|---|---|
| `--homes DIR` | `/volume1/homes` | where the per-user homes live |
| `--warn HOURS` | 30 | warn above this snapshot age |
| `--crit HOURS` | 54 | critical above this age |
| `--no-size` | off | skip `du`, the slow part on a big repository |
| `-h`, `--help` | | this list |

30 and 54 hours assume a daily backup: 30 means one run has been missed, 54 means two.

Exit code `0` all fresh, `1` at least one stale, `2` nothing found — so this can be the
check behind a cron job or a monitor.

---

# `config.json`

One file per machine, in the configuration directory, mode `600` / `SYSTEM` +
`Administrators`. **Not in version control**: it is the only place anything
site-specific lives.

```json
{
  "configVersion": 1,
  "machine": "MACHINENAME",
  "updated": "2026-09-27 16:20:00",
  "nas": {
    "host": "nas.example.ts.net",
    "user": "restic-machinename",
    "port": 22,
    "hostAlias": "nas-restic",
    "repoPath": "home/restic-repo"
  },
  "backupPaths": [ "C:\\Users\\someone" ],
  "retention": { "daily": 14, "weekly": 8, "monthly": 12 },
  "schedule": { "time": "03:30", "timeLimitHours": 20, "wakeToRun": false },
  "homeAssistant": { "host": "ha.example.lan", "port": 1883, "user": "restic-machinename",
                     "topic": "", "box": "" },
  "paths": { "base": "C:\\ProgramData\\restic", "tools": "C:\\Program Files\\restic-backup" }
}
```

| Key | Written by | Read by |
|---|---|---|
| `nas.*` | the installer, from parameters or the first-run prompt | everything |
| `backupPaths` | the installer | the backup script, `restic-ctl config` |
| `retention.*` | the installer | the backup script after a successful run |
| `schedule.time`, `schedule.timeLimitHours`, `schedule.wakeToRun` | `restic-ctl schedule`, then step 8 | step 8 (Windows) |
| `schedule.onCalendar`, `schedule.retryCalendar` | `restic-ctl schedule`, then step 8 | step 8 (Linux) |
| `paths.base`, `paths.tools` | the installer | `restic-ctl schedule`, to find the installer |
| `homeAssistant.*` | the installer (`-Ha*` / `--ha-*`) | the backup script, `restic-ctl config`. Empty `host` means off; empty `box` and `topic` are composed at run time. The MQTT password is **not** here: it is in `mqtt-password`, locked like the repository password |

`paths.tools` is the **tools** directory, not the `PATH` directory: on Linux
`/usr/local/lib/restic-backup`, while `/usr/local/bin` only holds the `restic-ctl` and
`restic-backup.sh` entry points. A machine set up before 2026.09.27.2 has `/usr/local/bin`
stored there by mistake; an `--update` rewrites it, and in the meantime
`restic-ctl schedule` also looks in the built-in default, so it still works.

**The repository string is not stored.** Every reader composes
`sftp:<hostAlias>:<repoPath>` itself, so the parts and the whole can never disagree.

A parameter typed on the command line wins over a stored value; a stored value wins over
a default. That rule is why re-running one step no longer reverts a machine to the
script's defaults — which once sent one machine's backup at another machine's NAS
account, a wrong-but-valid value that no check would catch.

Machines set up before `config.json` existed keep their answers in `settings.psd1` /
`settings.env` plus `ssh/config`; the installer reads both and converts on the next run,
so nothing has to be retyped.

---

# Exit codes

Same on both platforms, every script.

| Code | Meaning |
|---|---|
| 0 | fine |
| 1 | a problem worth acting on: a step failed, a repository is unreachable, a backup is stale |
| 2 | wrong usage: an unknown option, a retired one, a missing required answer, a bad time or calendar spec |
| 3 | `-Update` / `--update` refused because the copy you ran is older than the installed one |

`nas-fleet-status.sh` is the one with its own meaning for `1` and `2`: `1` at least one
machine stale, `2` no repositories found.

---

# Retired options

These were parameters of the installer and are now errors that tell you where to go. A
parameter that is accepted and quietly ignored is worse than one that is gone.

| Was | Now |
|---|---|
| `-TaskTime 03:30` | `restic-ctl schedule 03:30` |
| `-TimeLimitHours 24` | `restic-ctl schedule -TimeLimitHours 24` |
| `-WakeToRun` | `restic-ctl schedule -WakeToRun` |
| `--on-calendar '*-*-* 03:30'` | `sudo restic-ctl schedule '*-*-* 03:30'` |
| `--retry-calendar '*-*-* 19:17'` | `sudo restic-ctl schedule --retry '*-*-* 19:17'` |

Why they moved: the schedule is a property of a machine that is already set up, and
changing it should not mean re-running an installer. Worse, `-Only 8 -TaskTime 03:30`
changed the task while `config.json` still held the old value, and the next `-From 3`
would quietly put it back. `restic-ctl schedule` writes `config.json` and then calls step
8, so there is one writer for the task and one command to change it.

---

# Where Windows and Linux differ

Everything below is a real asymmetry, not an oversight.

| | Windows | Linux |
|---|---|---|
| Kill-after-N-hours | yes, `-TimeLimitHours`, default 20 — Task Scheduler terminates the run | **none**: a long first backup cannot be cut short |
| Retry after an interrupted run | Task Scheduler, 3 times 30 minutes apart | a second `OnCalendar` entry the same day |
| Catch up after the machine was off | `-StartWhenAvailable` | `Persistent=true` |
| Not on battery | Task Scheduler defaults: does not start, stops if unplugged | `ConditionACPower=true` |
| Wake to run | opt-in, `restic-ctl schedule -WakeToRun` | not offered |
| Keep the machine awake during a backup | Power Request API (`PowerSetRequest`) | `systemd-inhibit --what=idle --mode=block` |
| Filesystem snapshot | `--use-fs-snapshot` (VSS), which is why it needs elevation | none: open files are read as they are |
| Browse a repository as a filesystem | not available | `restic mount`, and it is the best verification tool here |
| Spread the start time | — | `RandomizedDelaySec=15m` |
| Paths inside a snapshot | keep the drive letter, forward slashes: `C:/Users/me/…` | ordinary paths |

One consequence worth stating: on Windows the time limit is a real risk and the reason
the default is 20 hours rather than 6. On Linux there is no limit at all, so the
equivalent worry does not exist — but neither does the protection against a run that
hangs forever, and `status` is what tells you.
