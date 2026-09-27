# Restic backups — this folder

| File | What it is |
|------|------------|
| **`RUNBOOK.md`** | **Start here.** Architecture, per-machine procedure, day-to-day commands, troubleshooting. |
| `restic-ctl.ps1` / `restic-ctl.sh` | Day-to-day driver: `status`, `snapshots`, `run`, `check`, `history`, `log`, `config`, plus a restic wrapper: `exec`, `forget`, `restore`, `ls`, `find`, `unlock` |
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
```

On Linux, `sudo restic-ctl status`. This folder is only the distribution copy: the
installer puts the tools in `C:\Program Files\restic-backup` (or `/usr/local/bin`),
so running it from a USB stick leaves the machine self-sufficient.

Anything restic can do, without retyping the connection:

```powershell
.\restic-ctl.ps1 exec stats latest
.\restic-ctl.ps1 forget <id> --dry-run
.\restic-ctl.ps1 restore latest -Target D:\restore-test
```

Every machine at once, from anywhere:

```bash
ssh <admin>@<nas> 'sudo sh -s' < nas-fleet-status.sh
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
