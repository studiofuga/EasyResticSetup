# Restic backups — this folder

| File | What it is |
|------|------------|
| **`RUNBOOK.md`** | **Start here.** Architecture, per-machine procedure, how to do things, troubleshooting, and why things are the way they are. |
| **`COMMANDS.md`** | The reference: every command and option of every script, Windows and Linux together. |
| `restic-ctl.ps1` / `restic-ctl.sh` | Day-to-day driver: `status`, `snapshots`, `run`, `check`, `schedule`, `history`, `log`, `config`, `help`, plus a restic wrapper: `exec`, `forget`, `restore`, `ls`, `find`, `unlock` |
| `nas-fleet-status.sh` | All machines at a glance; run on the NAS, uses no passwords |
| `Setup-ResticBackup.ps1` | Windows client installer, 9 idempotent steps |
| `setup-restic-backup.sh` | Linux client installer, same 9 steps |
| `nas-provision-<user>.sh` | Generated per machine by step 4; run it on the NAS |
| `reference/` | Superseded first drafts. Do not copy these into place. |

## Everyday

Once a machine is set up, the tools are installed on it and on PATH, so from **any
elevated** shell:

```powershell
restic-ctl status      # running? last outcome? failures? snapshot age? credentials?
restic-ctl run         # start a backup via the scheduler and follow it
restic-ctl history     # table of recent runs, failures included
restic-ctl schedule    # when does it run, and does the task agree with config.json
restic-ctl help        # the command index; "help <command>" for one command's detail
```

On Linux, `sudo restic-ctl status`. This folder is only the distribution copy: the
installer puts the tools in `C:\Program Files\restic-backup` (or
`/usr/local/lib/restic-backup`, with the entry points in `/usr/local/bin`), so running it
from a USB stick leaves the machine self-sufficient.

Anything restic can do, without retyping the connection:

```powershell
.\restic-ctl.ps1 exec stats latest
.\restic-ctl.ps1 forget <id> --dry-run
.\restic-ctl.ps1 restore latest -Target D:\restore-test
```

Every machine at once, from anywhere, using the dedicated fleet-status account
(setup in `RUNBOOK.md`):

```bash
ssh <fleet-status-user>@<nas> 'sudo /usr/local/bin/nas-fleet-status.sh'
```

## Setting up a new machine

```powershell
.\Setup-ResticBackup.ps1            # asks for the NAS address
.\Setup-ResticBackup.ps1 -NasHost nas.example.ts.net    # or answer up front
```
```bash
sudo ./setup-restic-backup.sh
sudo ./setup-restic-backup.sh --nas-host nas.example.ts.net
```

The NAS address has no default: nothing here is site-specific, so these files can sit
in version control unchanged. The answer goes to `config.json`, which does not. The NAS
account name is derived from the machine's hostname.

Both stop at step 6 and tell you to run the generated `nas-provision-*.sh` on the
NAS; then continue with `-From 6` / `--from 6`.

**Parameters are typed once.** They are stored in `config.json` on the machine and
become the defaults for every later run, so `-From 3` on its own no longer reverts
anything. A deliberate change to the NAS account, host or repository path asks for
confirmation, since that repoints the repository.

The full sequence, including what to set up in DSM first and the `/home` vs `/homes`
trap, is in `RUNBOOK.md`.

## Updating a machine already set up

Copy this folder over — a USB stick is the intended route, nothing here depends on git —
then, from the copy you brought and **not** from the installed one:

```powershell
.\Setup-ResticBackup.ps1 -Update
```
```bash
sudo ./setup-restic-backup.sh --update
```

Each script carries a version stamp and compares itself to the installed copy by version
and by hash. Installing an older version over a newer one stops with exit 3 — `-Force`
overrides it on purpose. If you edit a script yourself, bump its `SCRIPT_VERSION`.
