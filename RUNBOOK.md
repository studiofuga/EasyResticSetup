# restic backups to the Synology NAS — runbook

One NAS user and one repository per client machine. No shared credentials, so a
compromised client can reach only its own snapshots.

| Piece | Where |
|-------|-------|
| NAS user | `restic-<machine>`, DSM, no admin rights, login by key only |
| Repository, on the NAS disk | `/volume1/homes/restic-<machine>/restic-repo` |
| Repository, as restic addresses it | `sftp:nas-restic:home/restic-repo` |
| Reached over | SFTP, through Tailscale (`nas.example.ts.net`) or the LAN IP |
| Windows client | `C:\ProgramData\restic`, scheduled task as SYSTEM |
| Linux client | `/etc/restic`, systemd timer as root |
| Retention | 14 daily, 8 weekly, 12 monthly |

Naming convention: the NAS account is `restic-<machine>`, derived from the client's
hostname, so nothing has to be chosen per machine. The installers do this themselves.

**Where to look for what.** This runbook answers "how do I do X" and records why things
are the way they are. `COMMANDS.md` is the reference: every command of every script, both
platforms, with each option and what it costs. In the shell, `restic-ctl help` gives the
command index and `restic-ctl help <command>` the detail for one, and both installers take
`-Help` / `--help`.

### `/home` vs `/homes` — read this before anything else

An SFTP session for these accounts lands on Synology's **virtual root**, `/`, not
on the account's home. Two different things live near there:

- **`/home`, singular** — DSM's alias for the logged-in account's *own* home. It
  needs no permission on any shared folder, and it is where the repository goes.
  The path is therefore the same on every machine: `home/restic-repo`.
- **`/homes`, plural** — the shared folder holding everyone's homes. Reaching a
  repository as `homes/<user>/restic-repo` requires a permission on that share
  which a backup-only account normally does not have. It then fails with a bare
  `permission denied` from `restic init` — *even when the home's own owner, mode
  and ACL are all correct*, which makes it look like an ACL problem for hours.

One machine here predates this finding and still addresses its repository as
`homes/<its-account>/restic-repo`. It works, so it has been left alone; new machines
get the `home/restic-repo` default.

## Where things live

| | Windows | Linux |
|---|---------|-------|
| Executables | `C:\Program Files\restic-backup` (on PATH via `restic-ctl.cmd`) | `/usr/local/bin/restic-ctl`, `/usr/local/bin/restic-backup.sh` |
| Installer and docs | same folder | `/usr/local/lib/restic-backup` |
| Config, credentials, state | `C:\ProgramData\restic` | `/etc/restic` |
| Machine config | `config.json` | `config.json` |

Step 2 copies the installer, `restic-ctl` and the docs onto the machine, so one set up
from a USB stick or a checkout keeps working once that is gone — on both platforms.
`--tools-dir` / `-ToolsDir` moves the destination. Credentials never leave
the data folder, which stays readable only by SYSTEM and Administrators (root on
Linux).

### config.json

One file per machine, **same schema on both platforms**, read by the installer, the
backup script and `restic-ctl`:

```json
{
  "configVersion": 1,
  "machine": "WORKSTATION-1",
  "nas": { "host": "192.168.1.10", "user": "restic-<machine>", "port": 22,
           "hostAlias": "nas-restic", "repoPath": "home/restic-repo" },
  "backupPaths": ["C:\\Users\\<user>"],
  "retention": { "daily": 14, "weekly": 8, "monthly": 12 },
  "schedule": { "time": "13:00", "timeLimitHours": 20, "wakeToRun": false },
  "paths": { "base": "C:\\ProgramData\\restic", "tools": "C:\\Program Files\\restic-backup" }
}
```

The repository string is deliberately **not** stored: every reader composes
`sftp:{hostAlias}:{repoPath}`, so it cannot drift from its parts.

**The NAS address has no default and is asked for on a first run.** Nothing in these
scripts is site-specific, so they can live in version control as they are; the answers
go to `config.json`, which does not. The NAS account name is derived from the client's
hostname rather than asked for. Pass `-NasHost` / `--nas-host` to answer without a
prompt, which is also what an unattended run must do.

**Other parameters are typed once, on the first run.** After that the stored values are the
defaults, and a parameter on the command line overrides them — that is what
`$PSBoundParameters` / the `GIVEN` list is for. This matters because re-running one
step without `-NasUser` used to fall back to the script's default and repoint the
machine at another machine's NAS account: a wrong but valid value that fails no
check and writes into the wrong repository.

For that reason an explicit change to `NasUser`, `NasHost` or `RepoPath` asks you to
type `CHANGE` before proceeding (`-AcceptChanges` / `--accept-changes` to skip it in
a script). No automated check can tell "I am migrating this machine" from "I forgot a
parameter", so a human confirms it once.

**Migration is automatic.** A machine still on `settings.psd1` / `settings.env` is
converted on the next run: the installer reads the old file plus `ssh/config` — where
the NAS host and user live — writes `config.json`, and renames the old file to
`.migrated`. Nothing is retyped, including non-default values such as a machine whose
repository path is not the current default. Don't run the installer while a backup is
in progress.

## Files here

| File | Use |
|------|-----|
| `Setup-ResticBackup.ps1` | Windows client installer, 9 idempotent steps |
| `setup-restic-backup.sh` | Linux client installer, same 9 steps |
| `restic-ctl.ps1` / `restic-ctl.sh` | Day-to-day: status, snapshots, run, check, history, log, config |
| `nas-fleet-status.sh` | All machines at a glance, run on the NAS, no passwords |
| `nas-provision-<account>.sh` | Generated per machine by step 4; run it on the NAS. Not in version control: it embeds that machine's public key |
| `reference/` | Superseded first drafts, kept for reference only |

Both installers generate the NAS-side script, so the NAS procedure is never
retyped: it is one file per machine, with that machine's public key baked in.

## Checking on the backups

### Two sources of truth, and why it matters

Snapshot state lives in the **repository** and can be read from any machine that
has the password. Run state lives on the **client**, and this asymmetry is the
important part:

> The repository holds no trace of a backup that failed. A snapshot is written
> only when a run completes, so "how many backups failed" is not a question
> restic can answer.

So each backup run records its own outcome locally:

| File | Contents |
|------|----------|
| `progress.json` | while running: percent, files, bytes, ETA. Deleted at the end. |
| `last-run.json` | the latest run: outcome, exit code, duration, snapshot id, bytes added |
| `history.jsonl` | one line per run, last 500, **including failed ones** |

`progress.json` also solves a problem that has no other solution on either
platform: restic draws its progress bar only on a terminal, so a scheduled run
shows nothing. With `--json` it emits status objects regardless, and the backup
script throttles them into that file.

### restic-ctl

One entry point per platform, same subcommands. Windows needs an elevated shell,
Linux needs `sudo`, because the credentials are readable only by the account the
backup runs as.

```powershell
.\restic-ctl.ps1 status          # the one command to run when wondering
.\restic-ctl.ps1 snapshots
.\restic-ctl.ps1 run
.\restic-ctl.ps1 history
.\restic-ctl.ps1 check -Data
.\restic-ctl.ps1 log -Follow
.\restic-ctl.ps1 config
```
```bash
sudo restic-ctl status           # installed to /usr/local/bin by step 3
sudo restic-ctl snapshots --deep
sudo restic-ctl run
sudo restic-ctl history --count 40
sudo restic-ctl check --data
sudo restic-ctl log --follow
```

It is also the wrapper over restic itself, so the repository, the password file
and the `sftp.command` never get retyped:

```powershell
.\restic-ctl.ps1 exec stats latest
.\restic-ctl.ps1 exec diff 4f2a9c1b b9dd1b6d
.\restic-ctl.ps1 forget b9dd1b6d --dry-run
.\restic-ctl.ps1 forget b9dd1b6d               # asks for confirmation
.\restic-ctl.ps1 restore latest -Target D:\restore-test
.\restic-ctl.ps1 ls latest
.\restic-ctl.ps1 find "*.kdbx"
.\restic-ctl.ps1 unlock
```
```bash
sudo restic-ctl exec stats latest
sudo restic-ctl forget b9dd1b6d --dry-run
sudo restic-ctl forget b9dd1b6d --yes
sudo restic-ctl restore latest --target /var/tmp/restore-test
```

`exec` passes anything through, so there is no restic subcommand this does not
cover. `forget` is the exception: it adds `--prune` and, unless `--dry-run` is
given, asks you to type the number of snapshots before doing anything, because
forgetting plus pruning cannot be undone. `restore` refuses a target folder that
already has files in it, so a restore can never mix into real data.

`status` answers, in one screen: is a backup running and how far along, how the
last one went, how many of the last 30 runs failed, what the scheduler thinks and
when it will fire next, and how old the newest snapshot actually is.

That last line is the one worth trusting most. **A newest snapshot older than
about a day on a daily schedule means something is wrong**, whatever the
scheduler and the last recorded run claim — those describe a process, while the
snapshot age describes the outcome.

Fast by default: everything above reads local files and repository metadata.
`-Deep` / `--deep` adds `restic check` (structure, no data transfer); `check
-Data` / `check --data` re-reads 5% of the data blobs, which catches bit rot but
re-downloads that much.

### Starting a backup by hand

`restic-ctl run` starts it **through the scheduler** — `Start-ScheduledTask` on
Windows, `systemctl start` on Linux — not by calling the backup script. That is
deliberate: it exercises the real run context (SYSTEM or root, its network
credentials, Tailscale unattended), not just the script logic. A backup that
works when you run the script yourself and fails on schedule is the single most
common failure here, and invoking the scheduler is what reproduces it.

It then follows the progress and prints the outcome. `-NoWait` / `--no-wait`
starts it and returns.

### The whole fleet

```bash
ssh <fleet-status-user>@<nas> 'sudo /usr/local/bin/nas-fleet-status.sh'
```

Per machine: snapshot count, date and age of the newest, repository size, and
locks left by interrupted runs. It uses **no repository password** — the ages
come from the mtimes of the files in `snapshots/`, since restic encrypts the
contents but not the file names and dates.

An administrator account does not get more than that. Repository contents,
integrity checks and anything about a failed run need that repository's password,
which by design lives only on its own machine. A deeper fleet view would mean
keeping all four passwords in one place, which would undo the isolation the
per-machine accounts exist for. Exit code is 0 if every machine is fresh, 1 if
any is stale, so it also works as a cron check.

Verified against real repositories, run this way, on 2026-09-28.

### Setting up the fleet-status account

The script needs root — it reads the other accounts' homes, which are not
world-readable, and refuses to run otherwise:

```sh
[ "$(id -u)" = 0 ] || { echo 'run this with sudo: the homes are not world-readable.' >&2; exit 2; }
```

Running it under the built-in `admin` works but is the wrong shape for
something invoked unattended or from a script: it is a full DSM
administrator, and a key installed on it is worth more than the read-only
listing this is meant to grant. Give it its own account instead, scoped to
exactly this one script.

1. **DSM user.** Control Panel → User & Group → Create `<fleet-status-user>`,
   member of `administrators` (SSH and `sudo` on DSM 7 are restricted to that
   group; there is no narrower built-in role that still gets SSH).

2. **Key-only login, permissions fixed up front.** The first attempt at this
   (on a different admin account) failed silently: the server offered
   `publickey,password`, refused a key that was correctly listed in
   `authorized_keys`, and fell through to a password prompt — the classic
   sign of `sshd`'s `StrictModes` rejecting a home directory or `.ssh` that
   is group- or world-writable.
   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub <fleet-status-user>@<nas>
   ssh <fleet-status-user>@<nas> '
     chmod 755 ~ && chmod go-w ~
     chmod 700 ~/.ssh
     chmod 600 ~/.ssh/authorized_keys
   '
   ssh -o PreferredAuthentications=publickey <fleet-status-user>@<nas> 'echo OK'
   ```

3. **Install the script at a fixed path**, so sudo can name it exactly:
   ```bash
   scp nas-fleet-status.sh <fleet-status-user>@<nas>:/tmp/
   ssh <fleet-status-user>@<nas> 'sudo install -m 755 /tmp/nas-fleet-status.sh /usr/local/bin/nas-fleet-status.sh'
   ```

4. **Scope sudo to that one command** — `sudo visudo` on the NAS:
   ```
   <fleet-status-user> ALL=(root) NOPASSWD: /usr/local/bin/nas-fleet-status.sh
   ```
   Not `NOPASSWD: ALL`: that would make a leaked key for this account
   equivalent to root on the NAS. Passwordless sudo is still needed —
   otherwise the point of running this unattended is lost — it is just
   scoped to the one script, at the one path, with no arguments.

   *No-sudo alternative, considered and not taken:* `chgrp` the
   `restic-<machine>` repositories to a shared group and grant that group
   read access instead of using sudo at all. Rejected for now — it needs a
   recursive `chgrp`/`chmod` on every repository, repeated for each new
   machine, and the script's `id -u = 0` check would still have to be
   patched to accept a non-root reader. Scoped sudo gets the same isolation
   with one sudoers line and no change to the script.

A major DSM update can rewrite `/etc/sudoers`; if the scoped line disappears
after one, that is why.

## Adding a machine

### 1. Create the DSM user

Control Panel → User & Group → Create, named `restic-<machine>`:

- a long random password — never used, login is by key
- **not** a member of `administrators`
- Permissions: no shared folder beyond its own home
- Applications: deny everything; only SFTP has to work
- User Home Service must be **on** (User & Group → Advanced) *before* creating
  the user, so DSM creates the home with its ACL

That last point is the one that bites. A home created by hand later stays in
Synology's "Linux mode" with no ACL at all, and restic then fails with
`MkdirAll ...: permission denied` even though SSH authentication succeeds.

### 2. Run the client installer up to step 4

Windows, in an **elevated** PowerShell:

```powershell
cd C:\Users\<user>\Restic
.\Setup-ResticBackup.ps1 -NasHost nas.example.ts.net -NasUser restic-<machine>
```

Linux:

```bash
sudo ./setup-restic-backup.sh --nas-host nas.example.ts.net
```

The Linux default for the user is `restic-<hostname>`, so `--nas-user` is
usually unnecessary. Step 4 prints the repository password: **store it in the
password manager before continuing.** Without it the repository is
unrecoverable.

Step 4 also writes `nas-provision-restic-<machine>.sh` next to the installer.
Step 6 then stops, because the key is not on the NAS yet.

### 3. Run the generated script on the NAS

```bash
scp nas-provision-restic-<machine>.sh <admin>@<nas>:/tmp/
ssh <admin>@<nas>
sudo sh /tmp/nas-provision-restic-<machine>.sh && rm /tmp/nas-provision-restic-<machine>.sh
```

It checks the DSM user, fixes the home ownership and mode, adds the DSM ACL,
installs the public key, and prints the resulting state. Idempotent, so
re-running it after a change is free.

To regenerate it without touching anything local:
`-NasSetup` on Windows, `--nas-setup` on Linux.

### 4. Finish on the client

```powershell
.\Setup-ResticBackup.ps1 -From 6          # Windows
```
```bash
sudo ./setup-restic-backup.sh --from 6    # Linux
```

Steps 6–8 verify the key, probe write access, create the repository and install
the schedule.

### 5. Review the exclusions, then dry-run

The default list already excludes VM disk images by extension (`*.vhdx`,
`*.qcow2`, `*.vmdk`, …) and `Downloads`. Both are worth understanding rather
than inheriting:

- **VM images** are excluded even when there is room. A disk image of a running
  VM is captured mid-write and is usually not restorable, and it changes as a
  whole, so every run re-uploads all of it. A VM is backed up by exporting it or
  from inside the guest. On one machine here this single pattern accounted for over
  1 TB, about 90% of the first snapshot.
- **`Downloads`** is re-downloadable by definition, but the flip side is real:
  anything parked there and meant to be kept is not backed up.

**Cloud-synced folders are excluded as a general rule** — OneDrive, Nextcloud,
Dropbox, Google Drive, Insync and the rest, with new services added to that list
as they appear. Each service backs up its own content; restic backs up what lives
only on this machine, and the same bytes are not stored once per machine that
syncs them.

The consequence is worth stating plainly, because it is a real reduction in
coverage: **for those folders the service is the backup.** A file deleted and
purged there has no restic snapshot behind it.

This is the only genuinely per-machine work. The defaults cover browser caches,
package caches and build output, but each machine has its own large
re-creatable directories.

```powershell
notepad C:\ProgramData\restic\excludes.txt
& C:\ProgramData\restic\restic-backup.ps1 -DryRun
Get-Content C:\ProgramData\restic\logs\restic-backup.log -Tail 50
```
```bash
$EDITOR /etc/restic/excludes.txt
/usr/local/bin/restic-backup.sh --dry-run
tail -n 50 /var/log/restic-backup.log
```

Then the first real backup, without `-DryRun` / `--dry-run`. It takes a while.

## What differs between the two platforms

| | Windows | Linux |
|---|---------|-------|
| Runs as | SYSTEM, Task Scheduler | root, systemd timer |
| Config | `C:\ProgramData\restic` (ACL: SYSTEM + Administrators) | `/etc/restic` (root, 700) |
| Settings | `settings.psd1` | `settings.env` |
| Backup script | `restic-backup.ps1` | `/usr/local/bin/restic-backup.sh` |
| Log | `logs\restic-backup.log` | `/var/log/restic-backup.log` |
| Open files | `--use-fs-snapshot` (VSS) | none: no snapshot, live filesystem |
| Catch-up after downtime | `-StartWhenAvailable` | `Persistent=true` |
| Run time limit | 20 h, then **the task is killed** (`-TimeLimitHours`) | none: `Type=oneshot` disables the systemd timeout |
| Default paths | the user profile | `/home /etc` |

Paths and retention live in the settings file on both. Edit that, not the
backup script, which reads it on every run.

`--use-fs-snapshot` is why the Windows task needs admin rights: VSS makes open
files (Outlook, browser profiles, `NTUSER.DAT`) consistent. There is no direct
Linux equivalent unless the filesystem offers snapshots, so on Linux a file
written during the run may be captured mid-write.

## Tailscale

The Windows task runs as SYSTEM, so **Tailscale must be in "Run unattended"
mode** (tray icon → Preferences). Without it the tailnet drops at logout and the
task cannot reach the NAS. On Linux `tailscaled` is already a system service, so
nothing is needed.

Using the LAN IP instead of the Tailscale name works only on that network. Fine
for a desktop, wrong for a laptop. To switch later, re-run the installer with
the new `-NasHost` / `--nas-host` from step 3: it rewrites the ssh config, and
step 5 will ask to trust the host key under the new name.

## Day to day, without restic-ctl

`restic-ctl` wraps all of this; what follows is the raw equivalent, for when it is
missing or you need a restic subcommand it does not cover.

Snapshots, Windows:
```powershell
$env:RESTIC_REPOSITORY='sftp:nas-restic:home/restic-repo'
$env:RESTIC_PASSWORD_FILE='C:\ProgramData\restic\password'
restic -o "sftp.command=ssh -F C:/ProgramData/restic/ssh/config -o BatchMode=yes nas-restic -s sftp" snapshots
```

Linux:
```bash
export RESTIC_REPOSITORY='sftp:nas-restic:home/restic-repo'
export RESTIC_PASSWORD_FILE=/etc/restic/password
restic -o "sftp.command=ssh -F /etc/restic/ssh/config -o BatchMode=yes nas-restic -s sftp" snapshots
```

Same shape for `ls`, `restore`, `diff`, `check`. Progress of a running backup,
since both schedulers suppress restic's interactive output:

```powershell
Get-Content C:\ProgramData\restic\logs\restic-backup.log -Tail 20 -Wait
```
```bash
sudo kill -USR1 $(pgrep -x restic)
tail -f /var/log/restic-backup.log
```

Run a backup on demand:
```powershell
Start-ScheduledTask restic-backup ; Get-ScheduledTaskInfo restic-backup
```
```bash
sudo systemctl start restic-backup.service ; systemctl status restic-backup.service
```

**Test a restore at least once per machine.** An untested backup is a guess.
Restore a directory to a scratch location and compare it against the original.

## Troubleshooting

Everything below was hit for real during the first two setups.

| Symptom | Cause | Fix |
|---------|-------|-----|
| ssh keeps asking for a password | the key is not in the NAS user's `authorized_keys`, or the home / `.ssh` / `authorized_keys` are group- or world-writable so sshd ignores the file | run the generated NAS script |
| `Host key verification failed` | the host key is not in the `known_hosts` the config points at, or `UserKnownHostsFile` is missing from the config so ssh reads the profile's one | re-run the installer from step 3, then step 5 |
| ssh test hangs forever | `ssh -s sftp` on a *successful* login hands the session to the SFTP subsystem and waits on stdin | not a fault: the installers test with `sftp -b` instead |
| `MkdirAll ...: permission denied` at init, or `readdir` denied on the own home | the repository path goes through `homes/<user>/` (the shared folder) instead of `home/` (the per-user alias) | use `home/restic-repo`; see the `/home` vs `/homes` section |
| Same error, and the path is already `home/...` | the home has no DSM ACL ("Linux mode"), because it was created by hand rather than by DSM | run the generated NAS script; verify with `sudo synoacltool -get /volume1/homes/restic-<machine>` |
| `readdir("/homes")` denied | `/homes` grants `everyone::allow:--x`, traverse without list | expected, not a fault |
| `synoacltool -enforce-inherit` made things worse | it rewrites the ACL from the parent's inheritable set only, discarding the explicit `level:0` ACE | re-add the ACE afterwards; `has_ACL` must appear in the `Archive:` line |
| `sftp` works but `ssh` does not | the DSM user's shell is `/sbin/nologin` | expected and desirable; restic only needs the SFTP subsystem |
| SFTP session lands on `/`, not the home | Synology's SFTP root is the virtual root | expected: repository paths therefore start with `homes/<user>/` |
| `forget --prune` fails on a stale lock | a previous run was interrupted | both backup scripts run `restic unlock` before each backup |
| Backup works interactively, fails when scheduled, log says `UNPROTECTED PRIVATE KEY FILE` / `bad permissions` | Windows, and there are **two** independent causes, which surface one after the other. (1) The key is *owned* by the interactive admin account: Win32-OpenSSH requires the owner to be the current user, SYSTEM or Administrators, so the key is accepted for a manual run and refused for the SYSTEM task. (2) The key's ACL still *grants* the interactive account, because files created under `C:\ProgramData` inherit an entry for their creator from a CREATOR OWNER ACE, and neither `icacls /inheritance:r` (inherited entries only) nor `/grant:r` (named SIDs only) removes it | `takeown /F <key> /A` for the first, `icacls <key> /remove:g "<DOMAIN>\<user>"` for the second. ssh names the offending account in the log. Newer setups rebuild owner and ACL from scratch and assert the result; `restic-ctl status` reports both under **Credentials** |
| Backup works interactively, fails when scheduled, other causes | Tailscale not in "Run unattended", or credentials in a user profile the scheduler cannot read | credentials live in `C:\ProgramData\restic`, readable by SYSTEM; check Tailscale |
| A machine's `excludes.txt` predates new template rules | step 3 never overwrites it, on purpose | `Setup-ResticBackup.ps1 -Only 3 -ForceExcludes` — the old file is kept as `excludes.txt.bak` |
| Task hangs with no log output | ssh waiting at a password prompt nobody can answer | both configs set `BatchMode=yes`, which fails fast instead |
| Scheduled run stops partway with no error from restic | Task Scheduler hit the task's execution time limit and killed it | raise it: `Setup-ResticBackup.ps1 -From 8 -TimeLimitHours 24`. A first backup on a 1 TB profile took 10h25m, so the limit has to exceed a full re-read, not a typical incremental |
| PowerShell: `Riferimento a variabile non valido` | `"$Var:"` in a double-quoted string parses as a drive-qualified variable | write `"${Var}:"` |
| A generated `.sh` fails on the NAS with a bad interpreter | CRLF line endings or a BOM | the installers write LF without BOM; do not round-trip these files through Notepad |

## Verifying a machine is healthy

`restic-ctl status` covers it. The underlying commands, if you want them directly:

```powershell
Get-ScheduledTaskInfo restic-backup      # LastTaskResult should be 0
```
```bash
systemctl list-timers restic-backup.timer
journalctl -u restic-backup.service -n 20
```

And periodically, against the machine's own repository:

```
restic check            # structural integrity
restic snapshots        # is the most recent one recent?
restic stats latest
```

`restic check --read-data-subset 5%` re-reads a sample of the blobs; without the
subset argument it re-downloads the whole repository. Worth doing occasionally
over the LAN, not over a slow link.

## Updating a machine to a new version of the scripts

Distribution is a copy — a USB stick, a share, a checkout. No git is required on any
machine. What each machine needs is the folder; the installer then puts the tools into
place itself.

```powershell
.\Setup-ResticBackup.ps1 -Update
```
```bash
sudo ./setup-restic-backup.sh --update
```

`-Update` is steps 2 to 9 — install the tools, regenerate what is generated, re-verify
everything — with one guard in front. **No parameters:** the machine's own `config.json`
supplies them.

### The guard, and why it exists

Step 2 installs a copy of the installer onto the machine, which means every machine has
two: the one you brought over and the one already installed. Since the installed one sits
at a known path, it is the easy one to type — and running it would quietly reinstall the
older version over your update. So each script carries a `SCRIPT_VERSION` stamp and
compares itself with the installed copy:

| Verdict | What it means | What happens |
|---|---|---|
| no installed copy | first run on this machine | proceeds |
| same version | nothing to do | proceeds |
| running is newer | the normal update | proceeds, printing `old -> new` |
| **running is older** | you ran the installed copy, or the stick is stale | **stops, exit 3** |
| same version, different content | one of the two was edited | warns, proceeds |

A hash is compared as well as the version, which is what catches the last row: a version
I forgot to bump would otherwise hide a real difference.

To go back to an older version deliberately, `-Force` / `--force`.

### The order that works

1. Copy the folder onto the machine, into a **working** directory — not into the tools
   directory the installer manages.
2. Windows: check `restic-ctl status` says `State idle` first. Updating during a backup
   would rewrite the script under the running process.
3. `-Update` / `--update`.
4. Read two lines of the header: the NAS account must be this machine's, and `Config`
   must say either `config.json` or `migrated from …`.
5. If the machine predates a template change, `-Only 3 -ForceExcludes` and diff against
   the `.bak`.

## Changing the schedule

The time lives in two places that must agree: the scheduler, which actually fires it, and
`config.json`, which records the intent. One command changes both:

```powershell
restic-ctl schedule 03:30
```
```bash
sudo restic-ctl schedule '*-*-* 03:30'
```

It writes `config.json`, then calls step 8 of the installed installer to re-register, then
re-reads both sides and tells you whether they now agree. With no argument it only reports:

```
restic-ctl schedule
```

Also settable, on Windows: `-TimeLimitHours 24` (Task Scheduler kills the run at that
limit) and `-WakeToRun` / `-NoWakeToRun`. On Linux: `--retry '*-*-* 19:17'`, the second
same-day `OnCalendar` entry. A bare `HH:MM` works on both; on Linux it is expanded to
`*-*-* HH:MM`, because systemd would otherwise read it as a one-off today, and the
expression is validated with `systemd-analyze calendar` before anything is written.

**This used to be an installer parameter and no longer is.** `-TaskTime`,
`-TimeLimitHours`, `-WakeToRun`, `--on-calendar` and `--retry-calendar` now stop with a
message pointing here. Two reasons: re-running an installer to move a start time is the
wrong shape, and `-Only 8 -TaskTime 03:30` changed the task while `config.json` still held
the old value — so the next `-From 3` quietly put it back. The same drift as the
parameters that used to revert, just narrower.

**Do not change the time in taskschd.msc either.** The GUI edit survives until the next
run of step 8, which re-registers from `config.json`. The config file is the source of
truth; the task is a projection of it. `restic-ctl schedule` with no argument is what
tells you the two have diverged.

To see what is actually registered:

```powershell
restic-ctl schedule                    # both sides, and whether they agree
restic-ctl status                      # scheduler section, with the next run
Get-ScheduledTaskInfo restic-backup
```
```bash
sudo restic-ctl schedule
sudo restic-ctl status
systemctl list-timers restic-backup.timer
```

Editing `config.json` by hand and running step 8 works too, and is the better route for
retention or backup paths — those are read by the backup script on every run, so they need
no re-registration at all.

## Suspend, battery and interrupted runs

A suspend mid-backup drops the SSH connection and the run fails. On a laptop this is
the likeliest way for a backup to die, so it is handled in four places rather than
one — no single setting covers it.

| Layer | Windows | Linux |
|---|---------|-------|
| Don't start on battery | Task Scheduler default (the two `…OnBatteries` switches are deliberately **not** set) | `ConditionACPower=true` |
| Stop if unplugged mid-run | same default | — |
| Block *idle* sleep while running | `SetThreadExecutionState(ES_CONTINUOUS\|ES_SYSTEM_REQUIRED)` in the backup script | `systemd-inhibit --what=idle --mode=block` |
| Retry an interrupted run | `RestartCount 3`, 30 min apart | a second `OnCalendar` the same day |
| Catch up a missed trigger | `-StartWhenAvailable` | `Persistent=true` |

**What cannot be fixed:** closing the lid, or choosing Sleep from the Start menu. No
user-space program can veto those, on either OS. Blocking them would mean overriding
a decision the user made, which is not the backup's call.

That is acceptable because **an interrupted restic run is cheap**. Packs already
uploaded stay in the repository, so the next attempt resumes instead of restarting —
which is also why stopping the run when the machine is unplugged costs almost
nothing.

Verify the sleep block took effect, during a run:

```powershell
powercfg /requests        # expect a SYSTEM request from powershell.exe
```
```bash
systemd-inhibit --list
```

The backup log records which way it went: `idle sleep blocked for the duration of this
run`, or a `WARNING could not block idle sleep`. If you see the warning on Windows,
the API call was refused in the SYSTEM session and we need the Power Request API
instead — tell me and I will switch it.

If the machine is a desktop that sleeps rather than a laptop, add `-WakeToRun` on
Windows so the task wakes it at the scheduled time. It is off by default because
waking a laptop on battery only to skip the backup is pointless.

## Verifying a backup without the disk space for a restore

A full restore is the most expensive test, not the best one. Three layers answer three
different questions, and the two that matter most cost no local disk space at all.

### 1. Is the repository intact? — free

```bash
sudo restic-ctl check
```

Verifies that the index agrees with the pack files and that nothing referenced is
missing. Downloads nothing, writes nothing.

### 2. Are the stored bytes still good? — costs bandwidth, not disk

```bash
sudo restic-ctl check --data              # default fraction: 1/12
sudo restic-ctl check --subset 1/6
```

Re-reads that fraction of the pack files and verifies their hashes, which is what
catches bit rot. The data is streamed and discarded, so nothing lands on disk. `1/12`
monthly covers the whole repository over a year — the way to get complete verification
on a link or a schedule that cannot afford downloading everything at once.

### 3. Can you actually get a file back? — free, and this is the real question

Neither check above proves a restore works. `dump` writes to stdout, so it verifies the
whole path — open, decrypt, reassemble — using no disk:

```bash
# one file, byte-exact against the live copy
sudo restic-ctl exec dump latest /etc/fstab | diff - /etc/fstab && echo identical

# an entire subtree, reconstructed and thrown away
sudo restic-ctl exec dump --archive tar latest /etc | tar -t > /dev/null

# the entire snapshot: full data verification, zero disk, full download
sudo restic-ctl exec dump --archive tar latest / > /dev/null
```

The last one is the strongest verification available without space: every blob is
fetched, decrypted and reassembled into a real tar stream. If it completes, the snapshot
is restorable.

On Linux there is a better tool still, which also costs nothing:

```bash
sudo restic mount /mnt/restic
ls /mnt/restic/snapshots/latest/
diff -r /mnt/restic/snapshots/latest/etc /etc     # compare whatever you like
sudo umount /mnt/restic
```

A read-only FUSE view of every snapshot. Ideal for spot-checking many files, and for
answering "was this file in the backup a week ago". Needs FUSE, so Linux only — Windows
would need WinFsp.

### 4. A real restore — the only test of permissions and ownership

Worth doing once per machine even on a small subset, because `dump` does not exercise
how files land on disk:

```bash
sudo restic-ctl restore latest --target /var/tmp/restore-test --include /etc
```

`--include` keeps it to a few hundred MB. If even that will not fit, restore a single
directory, or point `--target` at an external disk.

**What to do routinely:** `check` often, `check --data --subset 1/12` monthly, and a
`dump --archive tar latest / > /dev/null` when a machine's backup has changed shape —
after a big exclude change, a repository move, or a restic upgrade.

## Reclaiming space after widening the exclusions

Tightening `excludes.txt` does not shrink snapshots that already exist. Their
data stays in the repository until every snapshot referencing it has been
forgotten **and** pruned — and retention keeps the oldest snapshot for a long
time, because a first snapshot is usually tagged daily *and* weekly *and*
monthly, so 14/8/12 can pin it for a year.

To drop a specific snapshot and actually reclaim its space:

```powershell
.\restic-ctl.ps1 forget <short-id> --dry-run    # see what would go
.\restic-ctl.ps1 forget <short-id>              # then do it
```

If it is the only snapshot the repository becomes empty and the next backup is a
full one again — which is the right move when the previous snapshot was mostly
data you have since excluded.

## Untested so far

Written and syntax-checked, but not yet exercised against the real NAS:

- the `synoacltool` branch of the provisioning script — no Synology here to test on
- `--json` progress parsing on Windows: tested with simulated restic output, not
  with restic itself
- the Power Request C# in the Windows backup script: it parses, and the log line
  `(power request set)` has been seen on a real run, but `powercfg /requests` has not yet
  corroborated it while a backup was running
- `restic-ctl schedule`: the config.json round-trip, the time validation and the handoff
  to step 8 were all tested for real, with a stub installer standing in for step 8 and
  PowerShell 7 standing in for 5.1. What has **not** been exercised is the last link —
  `Register-ScheduledTask` and `systemctl daemon-reload` actually taking the new value.
  Run `restic-ctl schedule` with no argument afterwards: it reports both sides and says
  whether they agree, which is exactly the check
- **Home Assistant: the fleet template.** The reporting itself is verified: on
  2026-09-30 a Windows machine (through Windows PowerShell 5.1) and a Linux one
  published to the Mosquitto add-on, the state reached Home Assistant and discovery
  created each device with its entities. Before that, a test broker had covered the
  failure paths on both platforms - failed backup, failed prune, dry run, bad
  password, broker down, `unpublish` - and byte-identical discovery payloads from
  Linux and Windows. A wrong broker address fails with the OS's "connection refused"
  in the log, before any credentials are sent, not with an authentication error.
  **Not yet seen** is the fleet template and automation in `HOME-ASSISTANT.md` inside
  Home Assistant. Their logic was run with Home Assistant's functions stubbed out (a
  stale machine, a failed one, one that never ran, one fine: three flagged), and the
  package parses as YAML and Jinja - but that is not Home Assistant. *Checking that it
  sees the machines* in `HOME-ASSISTANT.md` is the real test
- no **restore** has been verified on any machine. This is the real gap, not a detail:
  a backup that has never been restored from is a hypothesis. `restic-ctl help restore`
  lists three ways to test one without needing free disk space

Check each the first time you use it rather than assuming it works.
