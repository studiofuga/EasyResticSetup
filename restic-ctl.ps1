<#
.SYNOPSIS
    Inspect and control the restic backup on this machine.

.DESCRIPTION
    One entry point, several subcommands:

      status      is a backup running, how did the last one go, what does the
                  scheduler think, how many runs failed recently
      snapshots   what the repository holds: snapshots, age of the newest, totals
      run         start a backup THROUGH THE SCHEDULER, in the same context the
                  scheduled run uses, and follow it
      check       verify repository integrity
      schedule    show or change when the backup runs
      history     table of recent runs, including failed ones
      log         tail the backup log
      config      the effective settings of this machine
      publish     send the last result to Home Assistant now (--dry-run: show it)
      unpublish   remove this machine from Home Assistant
      help        the command list, or the detail for one command

    And, as a wrapper over restic itself, so the repository, the password file
    and the sftp.command never have to be retyped:

      exec        run any restic command against this repository
      forget      remove snapshots and prune, with a confirmation step
      restore     restore a snapshot into a new folder
      ls          list a snapshot's contents
      find        find a path across snapshots
      unlock      clear stale locks

    Fast by default: status, snapshots and history read local files and repository
    metadata only. -Deep adds a restic check; check -Data re-reads actual data.

    Reads C:\ProgramData\restic\config.json, so it needs no configuration of its
    own. Every subcommand except help needs an elevated shell, because the
    credentials are readable by SYSTEM and Administrators only.

    "restic-ctl help <command>" prints the detail for one command: its arguments,
    what it reads or changes, and what it costs to run.

.EXAMPLE
    .\restic-ctl.ps1 status

.EXAMPLE
    .\restic-ctl.ps1 run              # via the scheduler, then follows progress

.EXAMPLE
    .\restic-ctl.ps1 snapshots -Deep  # plus a structural check

.EXAMPLE
    .\restic-ctl.ps1 check -Data      # re-reads 5% of the data blobs

.EXAMPLE
    .\restic-ctl.ps1 forget b9dd1b6d --dry-run
    .\restic-ctl.ps1 forget b9dd1b6d            # asks for confirmation

.EXAMPLE
    .\restic-ctl.ps1 restore latest -Target D:\restore-test

.EXAMPLE
    .\restic-ctl.ps1 exec stats latest

.EXAMPLE
    .\restic-ctl.ps1 schedule             # what time does it run, and what is registered
    .\restic-ctl.ps1 schedule 03:30       # move it, and re-register the task

.EXAMPLE
    .\restic-ctl.ps1 publish --dry-run   # the MQTT topics and payloads, nothing sent

.EXAMPLE
    .\restic-ctl.ps1 help forget
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'snapshots', 'run', 'check', 'schedule', 'history', 'log',
                 'config', 'exec', 'forget', 'restore', 'unlock', 'ls', 'find', 'publish',
                 'unpublish', 'help')]
    [string] $Command = 'status',

    [string] $Base   = 'C:\ProgramData\restic',
    [switch] $Deep,          # status/snapshots: also run a structural check
    [switch] $Data,          # check: also re-read data blobs
    # Fraction of the data blobs that -Data re-reads. 1/12 means twelve monthly runs
    # cover the whole repository, which is how to get full verification on a link that
    # cannot afford downloading everything at once.
    [string] $Subset = '1/12',
    [int]    $Count  = 15,   # history/log: how many entries
    [switch] $Follow,        # log: keep watching
    [switch] $NoWait,        # run: start and return instead of following
    [switch] $Yes,           # forget: skip the confirmation prompt
    [string] $Target,        # restore: where to restore to
    [string] $TaskName = 'restic-backup',
    [switch] $Help,          # same as the help command, so -Help works anywhere
    [switch] $DryRun,        # publish, unpublish: print the messages, send nothing
                             # (--dry-run, the Linux spelling, works too)

    # schedule: 0 means "leave whatever is stored alone". The three of them used to be
    # parameters of Setup-ResticBackup.ps1, where they were the wrong shape: the
    # installer installs, and re-running it to move a start time meant re-running steps
    # that had nothing to do with the schedule.
    [int]    $TimeLimitHours = 0,
    [switch] $WakeToRun,
    [switch] $NoWakeToRun,

    # Everything not bound above, passed through to restic. This is what makes
    # the wrapper subcommands work without re-declaring each restic option.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Rest = @()
)

$ErrorActionPreference = 'Stop'

$CtlVersion = '2026.09.30.2'

# Which parameters were actually typed. "schedule -TimeLimitHours 0" has to be told
# apart from "schedule" with the default still sitting there.
$Given = @($PSBoundParameters.Keys)
function Was-Given([string]$Name) { return $script:Given -contains $Name }

# ------------------------------------------------------------------- help
#
# Handled before anything else, so "restic-ctl help" works on a machine that has no
# config.json yet and from a shell that is not elevated. Everything below this point
# needs both.

$HelpOverview = @'
restic-ctl - inspect and control the restic backup on this machine.

USAGE
  restic-ctl <command> [options]
  restic-ctl help [<command>]        detail for one command

  From cmd.exe or a shortcut, "restic-ctl" is the .cmd shim in
  C:\Program Files\restic-backup. In PowerShell, ".\restic-ctl.ps1" works too.
  Everything except help needs an elevated shell: the credentials under
  C:\ProgramData\restic are readable by SYSTEM and Administrators only.

READING  (fast - local files and repository metadata, no data transfer)
  status              is a backup running now, how the last one went, what the
                      scheduler thinks, how many recent runs failed
  snapshots           what the repository holds: the list, the age of the newest,
                      totals
  history             table of recent runs, the failed ones included
  log                 the tail of the backup log
  config              this machine's effective settings and where they live
  schedule            when the backup runs, stored intent vs registered task

ACTING
  run                 start a backup THROUGH THE SCHEDULER, in the same context
                      the scheduled run uses, and follow it
  check               verify the repository
  schedule <time>     move the start time and re-register the task
  forget <id>...      delete snapshots and prune, with a confirmation step
  restore [<id>]      restore a snapshot into a folder
  unlock              clear a stale repository lock
  publish [--dry-run] send this machine's last result to Home Assistant now;
                      --dry-run prints the topic and payload and sends nothing
  unpublish [--dry-run]
                      remove this machine's device and state from Home Assistant

PASSTHROUGH  (restic itself, with this machine's repository, password file and
              sftp.command already filled in)
  exec <args>...      any restic command
  ls [<id>] [path]    list a snapshot's contents
  find <pattern>      find a path across snapshots

COMMON OPTIONS
  -Base <dir>         where the configuration lives (default C:\ProgramData\restic)
  -Help               this text

  Per-command options are listed by "restic-ctl help <command>". The ones that
  come up most:
  -Deep               status, snapshots: add a structural check of the repository
  -Data [-Subset f]   check: re-read actual data blobs, default 1/12 of them
  -Count <n>          history, log: how many entries (default 15)
  -Follow             log: keep watching
  -NoWait             run: start the task and return instead of following it
  -Yes                forget: skip the confirmation prompt
  -Target <dir>       restore: where to restore to (required)

EXIT CODES
  0  fine    1  a problem worth acting on    2  wrong usage
'@

$HelpTopics = @{}

$HelpTopics['status'] = @'
restic-ctl status - is the backup healthy right now.

  restic-ctl status [-Deep]

Reads local state only, so it is instant and safe to run during a backup:
  State          idle, or running - and whether that comes from the scheduled
                 task, from a bare restic process, or is only a stale progress
                 file (reported as "maybe")
  Progress       when a backup is running: files and bytes done so far, from
                 progress.json, which the backup script writes from restic --json.
                 This is the only way to see progress from a scheduled run: it has
                 no terminal and therefore no progress bar.
  Last run       result, when, how long, what changed
  Scheduler      the task's state, last result and next run time
  Recent failures  counted from history.jsonl, because a failed run leaves no
                 trace in the repository at all
  Credentials    that the SSH key is owned by SYSTEM or Administrators and that
                 nobody else has been granted access - the two independent causes
                 of "UNPROTECTED PRIVATE KEY FILE"

-Deep also runs "restic check" (structure only, no data re-read). That contacts
the NAS and takes a minute or two on a large repository.
'@

$HelpTopics['snapshots'] = @'
restic-ctl snapshots - what the repository actually holds.

  restic-ctl snapshots [-Deep]

The snapshot list with its tags and paths, the age of the newest one, and the
repository totals from "restic stats". Metadata only: nothing file-sized is
downloaded.

Age is the number that matters. A repository can be perfectly healthy and
useless because the newest snapshot is three weeks old - a scheduled task that
has been failing quietly looks exactly like this.

-Deep also runs "restic check" (structure only).
'@

$HelpTopics['run'] = @'
restic-ctl run - start a backup the way the scheduler starts it.

  restic-ctl run [-NoWait]

Starts the scheduled task, it does not run restic itself. That matters: the task
runs as SYSTEM, with the SYSTEM environment, the SYSTEM view of network drives
and the credentials SYSTEM can read. A backup you launch by hand as yourself can
succeed while the scheduled one fails, and then you have tested nothing.

By default it follows the run: progress from progress.json, refreshed until the
task finishes. Ctrl-C stops watching, not the backup - the task keeps going.
-NoWait starts it and returns immediately.

If a backup is already running it refuses and points at "restic-ctl status".
'@

$HelpTopics['check'] = @'
restic-ctl check - verify the repository.

  restic-ctl check [-Data] [-Subset <fraction>]

Three levels, increasing in cost:

  (default)               structure: every index, tree and pack is referenced and
                          reachable. Metadata only, no data downloaded. Minutes.
  -Data -Subset 1/12      re-reads a twelfth of the data blobs and verifies their
                          hashes. This is the one that catches actual corruption.
                          Costs bandwidth, not disk: nothing is written locally.
                          Twelve monthly runs cover the whole repository.
  -Data -Subset 100%      re-reads everything. On this repository that is hundreds
                          of gigabytes over SFTP.

-Subset implies -Data. It takes either a fraction (1/12) or a percentage (5%).

What check cannot tell you is whether a restore works. For that, see
"restic-ctl help restore" - and note that "exec dump" verifies a file end to end
without needing any free disk space.
'@

$HelpTopics['schedule'] = @'
restic-ctl schedule - show or change when the backup runs.

  restic-ctl schedule                        show
  restic-ctl schedule <HH:mm>                move the daily start time
  restic-ctl schedule [<HH:mm>] -TimeLimitHours <n>
  restic-ctl schedule [<HH:mm>] -WakeToRun | -NoWakeToRun

With no argument it shows both sides and says whether they agree: the intent
stored in config.json, and what Task Scheduler actually has registered - start
time, time limit, wake setting, last result, next run.

With an argument it writes config.json first, then re-registers the task by
calling step 8 of the installed Setup-ResticBackup.ps1, then re-reads both to
confirm. The registration lives in one place on purpose; two pieces of code
writing the same task is how they drift apart.

  -TimeLimitHours <n>   Task Scheduler KILLS the run at this limit. The default
                        is 20. A first backup with no parent snapshot has to read
                        and hash everything: on a 1 TB profile that took 10h25m,
                        so the 6 hours that looked generous would have terminated
                        it halfway.
  -WakeToRun            wake the machine at the start time. Off by default:
                        waking a laptop on battery only to skip the backup
                        achieves nothing. On a desktop that sleeps, turn it on.
  -NoWakeToRun          turn that back off.

Not settable here, and deliberately: the task does not start on battery and
stops if the machine is unplugged, and it retries three times 30 minutes apart.
Those are the laptop-friendly defaults and the retry is what turns a backup
interrupted by a suspend into a completed one.

Needs the installer present in the tools directory. If it is missing, the
command prints the exact line to run instead.
'@

$HelpTopics['history'] = @'
restic-ctl history - the recent runs, including the ones that failed.

  restic-ctl history [-Count <n>]

Reads history.jsonl, appended by the backup script at the end of every run.
This file exists because the repository has no record of a failed backup: if the
run died, there is no snapshot, and "restic snapshots" shows nothing unusual.

Columns: when it started, how long it took, the result, new and changed files,
bytes added, and the snapshot id when there is one.

-Count defaults to 15.
'@

$HelpTopics['log'] = @'
restic-ctl log - the backup log.

  restic-ctl log [-Count <n>] [-Follow]

The tail of C:\ProgramData\restic\logs\restic-backup.log, written by the backup
script on every run. -Follow keeps watching, for a backup in progress.

For a running backup, "status" is usually the better view: the log records what
happened at each stage, while progress.json carries the live counters.
'@

$HelpTopics['config'] = @'
restic-ctl config - this machine's effective settings.

  restic-ctl config

Where the configuration lives, the NAS account and port, the tools directory,
the composed repository string, the SSH config, the backup paths, the retention
policy, then every file the system uses with its size and age, then the active
exclude patterns.

The repository string is composed from hostAlias and repoPath every time it is
needed, never stored. Two copies of the same string is one copy too many.

To change any of it, edit config.json and then re-run the installer from step 3
so the generated files follow. The exception is the schedule, which has its own
command: "restic-ctl schedule".
'@

$HelpTopics['exec'] = @'
restic-ctl exec - any restic command, against this repository.

  restic-ctl exec <restic arguments>...

The repository, the password file, the cache directory and the sftp.command are
already set, so this is plain restic with the connection filled in.

  restic-ctl exec snapshots --json
  restic-ctl exec stats latest
  restic-ctl exec diff 4f2a9c1b b9dd1b6d
  restic-ctl exec dump latest "C:/Users/me/notes.txt" > NUL

That last one is worth knowing: dump streams a file out of the repository and
verifies it end to end without writing anything to disk. It is how to prove a
restore works on a machine with no room for one.

No confirmation and no guard rails here - it is restic. Destructive commands
have their own wrappers ("forget") for exactly that reason.
'@

$HelpTopics['forget'] = @'
restic-ctl forget - delete snapshots and reclaim the space.

  restic-ctl forget <snapshot-id>... [--dry-run] [-Yes]

Removes the named snapshots, then prunes. Pruning is what actually frees space
on the NAS; forgetting alone only unlinks the snapshot.

  restic-ctl forget b9dd1b6d --dry-run     say what would go, change nothing
  restic-ctl forget b9dd1b6d               show it, then ask before doing it
  restic-ctl forget b9dd1b6d -Yes          no prompt

Always --dry-run first. Data shared with other snapshots is kept, so the space
freed is often far less than the snapshot's apparent size - and occasionally far
more than you expected.

Note that the scheduled backup already applies the retention policy from
config.json after every successful run. This command is for a specific snapshot
you want gone now.
'@

$HelpTopics['restore'] = @'
restic-ctl restore - restore a snapshot into a folder.

  restic-ctl restore [<snapshot-id>] -Target <folder>

The snapshot id defaults to "latest". -Target is required, must be empty or
absent, and must not be inside a path that is itself being backed up.

A full restore needs as much free space as the snapshot holds, which is why no
machine here has had one verified yet. Two ways to verify without that space:

  restic-ctl exec dump latest "<path in the snapshot>" > NUL
      streams one file through and checks its hashes. Zero disk.
  restic-ctl restore latest -Target D:\restore-test --include "C:/Users/me/Documents"
      a real restore of one subtree, which is a genuine end-to-end test at a
      size you can afford.

Paths inside a Windows snapshot keep their drive letter and use forward slashes:
"C:/Users/me/Documents". Get them from "restic-ctl ls latest".
'@

$HelpTopics['unlock'] = @'
restic-ctl unlock - clear a stale repository lock.

  restic-ctl unlock

restic locks the repository while writing. A run killed mid-flight - a suspend,
a time limit, a hard power cut - can leave that lock behind, and the next backup
then fails with "repository is already locked".

Only run this when no backup is actually running. Check with "restic-ctl status"
first: removing the lock out from under a live run is how a repository gets
damaged.
'@

$HelpTopics['publish'] = @'
restic-ctl publish - send this machine's backup state to Home Assistant.

  restic-ctl publish             send it now
  restic-ctl publish --dry-run   print the topics and the payloads, send nothing
                                 (-DryRun works too)

The same two messages the backup sends at the end of every run, over MQTT with QoS 1
and the retain flag, to the broker in the homeAssistant section of config.json:

  homeassistant/device/<id>/config   MQTT discovery. Home Assistant creates the
                                     device and its entities from it, so nothing
                                     is configured on the HA side for each machine.
  restic/<box>                       the state: last-run.json plus "box" and
                                     "publishedAt". A machine that has never run a
                                     backup sends outcome "never".

Use it to check the broker settings without waiting for a backup, or to put a
machine's state back after the retained message was cleared on the broker.

--dry-run does not contact the broker and writes nothing to the log. It also works
before a broker is configured, to see what the machine would send; the password
is never printed, only whether one is stored.

The work is done by restic-backup.ps1 (-Publish, -Publish -DryRun), so this
command reports exactly what a scheduled run would send. A machine whose
restic-backup.ps1 predates it says so: re-run Setup-ResticBackup.ps1 -Update.

Exit codes: 0 sent (or previewed), 1 the broker did not accept it, 2 Home
Assistant is not configured.
'@

$HelpTopics['unpublish'] = @'
restic-ctl unpublish - remove this machine from Home Assistant.

  restic-ctl unpublish             remove it now
  restic-ctl unpublish --dry-run   print the two topics it would clear
                                   (-DryRun works too)

Sends an empty retained message to both topics publish uses. Home Assistant removes
the device and its entities, and the broker forgets the last state.

The next backup announces the machine again. To retire it, stop the scheduled task
first, then unpublish (from an elevated prompt):

  Disable-ScheduledTask -TaskName restic-backup
  restic-ctl unpublish

A machine that no longer exists can be removed from Home Assistant itself:
Settings > Devices & services > MQTT > the device > Delete.

Exit codes: 0 removed (or previewed), 1 the broker did not accept it, 2 Home
Assistant is not configured.
'@

$HelpTopics['ls'] = @'
restic-ctl ls - list what is inside a snapshot.

  restic-ctl ls [<snapshot-id>] [<path>] [restic options]

Defaults to the latest snapshot. Useful for finding the exact spelling of a path
to hand to restore or dump.

  restic-ctl ls latest
  restic-ctl ls latest "C:/Users/me/Documents"
  restic-ctl ls b9dd1b6d --long

Paths inside a Windows snapshot keep the drive letter and use forward slashes.
'@

$HelpTopics['find'] = @'
restic-ctl find - which snapshots contain a given path.

  restic-ctl find <pattern> [restic options]

Searches every snapshot, so it is slower than ls. Patterns are globs.

  restic-ctl find "notes.txt"
  restic-ctl find "*.kdbx"
  restic-ctl find "**/Documents/tax-2025*"

The answer to "did that file ever get backed up, and when did it last change".
'@

function Show-Help([string]$Topic) {
    if (-not $Topic) {
        Write-Host ''
        $script:HelpOverview -split "`n" | ForEach-Object {
            if ($_.Trim()) { Write-Host "  $_" } else { Write-Host '' } }
        Write-Host ''
        return
    }
    $key = $Topic.ToLower()
    if ($script:HelpTopics.ContainsKey($key)) {
        Write-Host ''
        $script:HelpTopics[$key] -split "`n" | ForEach-Object {
            if ($_.Trim()) { Write-Host "  $_" } else { Write-Host '' } }
        Write-Host ''
    } else {
        Write-Host ''
        Write-Host "  No help topic '$Topic'." -ForegroundColor Yellow
        Write-Host ("  Topics: {0}" -f (($script:HelpTopics.Keys | Sort-Object) -join ', ')) -ForegroundColor DarkGray
        Write-Host ''
        exit 2
    }
}

if ($Help -or $Command -eq 'help') {
    Show-Help ($Rest | Select-Object -First 1)
    exit 0
}

# ---------------------------------------------------------------- settings

$ConfigFile = Join-Path $Base 'config.json'
$LegacyPsd1 = Join-Path $Base 'settings.psd1'

if (-not (Test-Path $ConfigFile)) {
    if (Test-Path $LegacyPsd1) {
        Write-Host "This machine still uses the old settings.psd1." -ForegroundColor Yellow
        Write-Host "Run Setup-ResticBackup.ps1 -From 3 once; it converts it to config.json." -ForegroundColor Yellow
    } else {
        Write-Host "No backup configured on this machine: $ConfigFile not found." -ForegroundColor Red
        Write-Host "Run Setup-ResticBackup.ps1 first." -ForegroundColor Yellow
    }
    exit 1
}
try {
    $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
} catch {
    Write-Host "Cannot read $ConfigFile - is this shell elevated?" -ForegroundColor Red
    exit 1
}

# Composed, not stored, so the repository string can never drift from its parts.
$Settings = [pscustomobject]@{
    Repository  = "sftp:$($Config.nas.hostAlias):$($Config.nas.repoPath)"
    SshConfig   = (Join-Path $Base 'ssh\config') -replace '\\', '/'
    HostAlias   = $Config.nas.hostAlias
    BackupPaths = @($Config.backupPaths)
    Retention   = [pscustomobject]@{
        Daily   = $Config.retention.daily
        Weekly  = $Config.retention.weekly
        Monthly = $Config.retention.monthly
    }
}

$LogFile      = Join-Path $Base 'logs\restic-backup.log'
$ProgressFile = Join-Path $Base 'progress.json'
$LastRunFile  = Join-Path $Base 'last-run.json'
$HistoryFile  = Join-Path $Base 'history.jsonl'
$PasswordFile = Join-Path $Base 'password'

$env:RESTIC_REPOSITORY    = $Settings.Repository
$env:RESTIC_PASSWORD_FILE = $PasswordFile
$env:RESTIC_CACHE_DIR     = Join-Path $Base 'cache'
$ResticOpts = @('-o', "sftp.command=ssh -F $($Settings.SshConfig) -o BatchMode=yes $($Settings.HostAlias) -s sftp")

# ---------------------------------------------------------------- helpers

function Write-Head([string]$Text) {
    Write-Host ''
    Write-Host "  $Text" -ForegroundColor White
    Write-Host ("  " + ('-' * $Text.Length)) -ForegroundColor DarkGray
}
function Write-Field([string]$Label, [string]$Value, [string]$Color = 'Gray') {
    Write-Host ("  {0,-18}" -f $Label) -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor $Color
}
function Write-Cont([string]$Value, [string]$Color = 'Gray') {
    Write-Host ("  {0,-18}" -f '') -NoNewline
    Write-Host $Value -ForegroundColor $Color
}
function Write-Info([string]$Value) { Write-Cont $Value 'DarkGray' }
function Write-Warn([string]$Value) {
    Write-Host '    WARN  ' -NoNewline -ForegroundColor Yellow
    Write-Host $Value -ForegroundColor Yellow
}
function Write-Fail([string]$Value) {
    Write-Host '    FAIL  ' -NoNewline -ForegroundColor Red
    Write-Host $Value -ForegroundColor Red
}
function Write-Ok([string]$Value) {
    Write-Host '    OK    ' -NoNewline -ForegroundColor Green
    Write-Host $Value -ForegroundColor Green
}

function Format-Bytes([double]$Bytes) {
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

function Format-Duration([double]$Seconds) {
    if ($null -eq $Seconds -or $Seconds -lt 0) { return '?' }
    $t = [TimeSpan]::FromSeconds([math]::Round($Seconds))
    if ($t.TotalHours -ge 1) { return ('{0}h{1:00}m' -f [int]$t.TotalHours, $t.Minutes) }
    if ($t.TotalMinutes -ge 1) { return ('{0}m{1:00}s' -f [int]$t.TotalMinutes, $t.Seconds) }
    return ('{0}s' -f $t.Seconds)
}

function Read-Json([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content $Path -Raw | ConvertFrom-Json) } catch { return $null }
}

function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try   { $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" } }
    finally { $ErrorActionPreference = $previous }
    return $out
}

function Invoke-Restic([string[]]$Arguments) {
    return Invoke-Native 'restic.exe' ($ResticOpts + $Arguments)
}

# A backup counts as running only if restic is alive AND the progress file is fresh.
# Either alone lies: a crashed run leaves a stale file, and a run that just started
# has no file yet.
function Get-RunState {
    $proc     = @(Get-Process restic -ErrorAction SilentlyContinue)
    $progress = Read-Json $ProgressFile
    $fresh    = $false
    if ($progress -and $progress.updated) {
        try { $fresh = ((Get-Date) - [datetime]$progress.updated).TotalMinutes -lt 5 } catch { }
    }
    return [pscustomobject]@{
        Running   = ($proc.Count -gt 0)
        Processes = $proc
        Progress  = $progress
        Fresh     = $fresh
    }
}

function Get-History([int]$Last = 0) {
    if (-not (Test-Path $HistoryFile)) { return @() }
    $lines = @(Get-Content $HistoryFile -ErrorAction SilentlyContinue |
               Where-Object { $_.Trim() })
    if ($Last -gt 0 -and $lines.Count -gt $Last) {
        $lines = $lines[($lines.Count - $Last)..($lines.Count - 1)]
    }
    return @($lines | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { $null }
    } | Where-Object { $_ })
}

function Get-OutcomeColor([string]$Outcome) {
    switch ($Outcome) {
        'ok'           { 'Green' }
        'warnings'     { 'Yellow' }
        'failed'       { 'Red' }
        'prune-failed' { 'Red' }
        default        { 'Gray' }
    }
}

# =============================================================== status

function Show-Status {
    Write-Host ''
    Write-Host ("  restic backup - {0}" -f $env:COMPUTERNAME) -ForegroundColor Cyan -NoNewline
    Write-Host ("      {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm')) -ForegroundColor DarkGray

    # --- running backup
    Write-Head 'Current run'
    $state = Get-RunState
    if ($state.Running -and $state.Progress -and $state.Fresh) {
        $p = $state.Progress
        $since = try { [datetime]$p.startedAt } catch { $null }
        $for = if ($since) { Format-Duration ((Get-Date) - $since).TotalSeconds } else { '?' }
        Write-Field 'State' "RUNNING for $for" 'Yellow'

        $bar = ''
        if ($p.percentDone -ne $null) {
            $filled = [int]([math]::Round($p.percentDone / 5))
            $bar = '[' + ('#' * $filled) + ('.' * (20 - $filled)) + ']'
        }
        Write-Field 'Progress' ("{0} {1,5:N1}%" -f $bar, $p.percentDone) 'White'
        Write-Cont ("{0:N0} of {1:N0} files, {2} of {3}" -f `
            $p.filesDone, $p.totalFiles, (Format-Bytes $p.bytesDone), (Format-Bytes $p.totalBytes))
        if ($p.secondsRemaining) {
            Write-Cont ("ETA ~{0}" -f (Format-Duration $p.secondsRemaining))
        }
        if ($p.currentFile) { Write-Cont ("at {0}" -f $p.currentFile) 'DarkGray' }
    }
    elseif ($state.Running -and -not $state.Fresh) {
        Write-Field 'State' 'restic is running but its progress file is stale' 'Yellow'
        Write-Cont 'It may be in forget/prune, or the run just started.'
    }
    elseif ($state.Running) {
        Write-Field 'State' 'restic is running (no progress yet)' 'Yellow'
    }
    else {
        Write-Field 'State' 'idle' 'Gray'
        if (Test-Path $ProgressFile) {
            Write-Cont 'A stale progress.json is left over from an interrupted run.' 'DarkYellow'
        }
    }

    # --- last completed run
    Write-Head 'Last completed run'
    $last = Read-Json $LastRunFile
    if (-not $last) {
        Write-Field 'State' 'no run recorded yet' 'DarkYellow'
    } else {
        $when = try { ([datetime]$last.finishedAt).ToString('yyyy-MM-dd HH:mm') } catch { $last.finishedAt }
        $age  = try { Format-Duration ((Get-Date) - [datetime]$last.finishedAt).TotalSeconds } catch { '?' }
        Write-Field 'Outcome' ("{0}   ({1} ago, took {2})" -f `
            $last.outcome.ToUpper(), $age, (Format-Duration $last.durationSec)) (Get-OutcomeColor $last.outcome)
        Write-Cont "finished $when, exit code $($last.exitCode), as $($last.runAs)"
        if ($last.snapshotId) {
            Write-Cont ("snapshot {0}  -  {1:N0} new / {2:N0} changed files, {3} added" -f `
                $last.snapshotId.Substring(0, [math]::Min(8, $last.snapshotId.Length)),
                $last.filesNew, $last.filesChanged, (Format-Bytes $last.dataAddedBytes))
        }
    }

    # --- recent outcomes
    $hist = Get-History
    if ($hist.Count -gt 0) {
        $recent = @($hist | Select-Object -Last 30)
        $bad    = @($recent | Where-Object { $_.outcome -notin @('ok', 'warnings') })
        $warn   = @($recent | Where-Object { $_.outcome -eq 'warnings' })
        $color  = if ($bad.Count -gt 0) { 'Red' } elseif ($warn.Count -gt 0) { 'Yellow' } else { 'Green' }
        Write-Field 'Recent runs' ("{0} recorded, {1} failed, {2} with warnings" -f `
            $recent.Count, $bad.Count, $warn.Count) $color
        if ($bad.Count -gt 0) {
            $lastBad = $bad[-1]
            Write-Cont ("last failure {0} (exit {1})" -f $lastBad.finishedAt, $lastBad.exitCode) 'Red'
            Write-Cont "restic-ctl.ps1 history   for the full table" 'DarkGray'
        }
    }

    # --- scheduler
    Write-Head 'Scheduler'
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Field 'Task' "'$TaskName' is not registered" 'Red'
        Write-Cont 'Nothing will run automatically. Setup-ResticBackup.ps1 -From 8' 'Yellow'
    } else {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        $tcol = if ($task.State -eq 'Disabled') { 'Red' } else { 'Green' }
        Write-Field 'Task' ("{0}   {1}" -f $TaskName, $task.State) $tcol
        Write-Cont ("runs as {0}" -f $task.Principal.UserId)
        if ($info.LastRunTime -and $info.LastRunTime.Year -gt 1999) {
            # 267009 means "task is currently running"; 0 means the last run succeeded.
            $rcol = if ($info.LastTaskResult -eq 0) { 'Gray' }
                    elseif ($info.LastTaskResult -eq 267009) { 'Yellow' } else { 'Red' }
            $rtxt = if ($info.LastTaskResult -eq 267009) { 'currently running' }
                    else { "result 0x{0:X}" -f $info.LastTaskResult }
            Write-Cont ("last  {0:yyyy-MM-dd HH:mm}   {1}" -f $info.LastRunTime, $rtxt) $rcol
        } else {
            Write-Cont 'never run' 'DarkYellow'
        }
        if ($info.NextRunTime) {
            Write-Cont ("next  {0:yyyy-MM-dd HH:mm}" -f $info.NextRunTime)
        } else {
            Write-Cont 'no next run scheduled' 'DarkYellow'
        }
    }

    # --- credentials the scheduled task will actually be able to use
    Write-Head 'Credentials'
    $keyFile = Join-Path $Base 'ssh\id_ed25519'
    if (-not (Test-Path $keyFile)) {
        Write-Field 'SSH key' 'missing' 'Red'
    } else {
        # Win32-OpenSSH refuses a private key unless its OWNER is the current user,
        # SYSTEM, or Administrators. A key left owned by the interactive admin works
        # by hand and is rejected when the task runs as SYSTEM - the backup then fails
        # with "bad permissions" and falls back to password auth. Checked here because
        # nothing else surfaces it until a scheduled run fails.
        $ownerOk = $false
        $ownerName = '?'
        try {
            $ownerName = (Get-Acl $keyFile).Owner
            $sid = (New-Object System.Security.Principal.NTAccount($ownerName)).Translate(
                       [System.Security.Principal.SecurityIdentifier]).Value
            $ownerOk = $sid -in @('S-1-5-18', 'S-1-5-32-544')
        } catch { }

        if ($ownerOk) {
            Write-Field 'SSH key owner' "$ownerName" 'Green'
        } else {
            Write-Field 'SSH key owner' $ownerName 'Red'
            Write-Cont 'ssh will refuse this key when the task runs as SYSTEM: the owner' 'Red'
            Write-Cont 'must be SYSTEM or Administrators, not a user account.' 'Red'
            Write-Cont "Fix:  takeown /F `"$keyFile`" /A" 'Yellow'
        }

        # Who else can read it. ssh refuses the key if anyone besides SYSTEM and
        # Administrators has access, and names the offender in its own error - but only
        # after a run has already failed. Files created under C:\ProgramData inherit an
        # entry for their creator, so this is the normal way for it to go wrong.
        $allowed = @('S-1-5-18', 'S-1-5-32-544')
        $extra = @()
        try {
            foreach ($rule in (Get-Acl $keyFile).Access) {
                $s = try {
                        $rule.IdentityReference.Translate(
                            [System.Security.Principal.SecurityIdentifier]).Value
                     } catch { $null }
                if ($s -and $s -notin $allowed) { $extra += "$($rule.IdentityReference)" }
            }
            $extra = @($extra | Select-Object -Unique)
        } catch { }

        if ($extra.Count -eq 0) {
            Write-Field 'SSH key access' 'SYSTEM and Administrators only' 'Green'
        } else {
            Write-Field 'SSH key access' ("also granted to: {0}" -f ($extra -join ', ')) 'Red'
            Write-Cont 'ssh will ignore the key and fall back to password auth, which fails.' 'Red'
            foreach ($who in $extra) {
                Write-Cont ("Fix:  icacls `"{0}`" /remove:g `"{1}`"" -f $keyFile, $who) 'Yellow'
            }
        }
    }

    # --- reachability and repository
    Write-Head 'Repository'
    Write-Field 'Target' $Settings.Repository
    $snap = Invoke-Restic @('snapshots', '--json', '--latest', '1')
    if ($LASTEXITCODE -ne 0) {
        Write-Field 'Reachable' 'NO' 'Red'
        Write-Cont (($snap | Select-Object -First 3) -join ' ') 'DarkGray'
    } else {
        $parsed = try { ($snap -join '') | ConvertFrom-Json } catch { $null }
        if (-not $parsed -or @($parsed).Count -eq 0) {
            Write-Field 'Reachable' 'yes, but the repository has no snapshots' 'DarkYellow'
        } else {
            $newest = @($parsed)[0]
            $age = try { ((Get-Date) - [datetime]$newest.time) } catch { $null }
            # Two days without a snapshot on a daily schedule means something is wrong,
            # even if the last recorded run says it succeeded.
            $acol = if (-not $age) { 'Gray' }
                    elseif ($age.TotalDays -gt 2) { 'Red' }
                    elseif ($age.TotalDays -gt 1.2) { 'Yellow' } else { 'Green' }
            Write-Field 'Newest snapshot' ("{0:yyyy-MM-dd HH:mm}   ({1} ago)" -f `
                [datetime]$newest.time, (Format-Duration $age.TotalSeconds)) $acol
            Write-Cont ("id {0}, host {1}" -f $newest.short_id, $newest.hostname)
        }
    }

    if ($Deep) {
        Write-Head 'Integrity'
        Invoke-Check -IncludeData:$false
    } else {
        Write-Host ''
        Write-Host '  -Deep adds a structural check of the repository.' -ForegroundColor DarkGray
    }
    Write-Host ''
}

# ============================================================ snapshots

function Show-Snapshots {
    Write-Host ''
    Write-Field 'Repository' $Settings.Repository
    $json = Invoke-Restic @('snapshots', '--json')
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host '  Cannot reach the repository.' -ForegroundColor Red
        $json | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        exit 1
    }
    # Assigned to a variable first, then wrapped. PowerShell 5.1's ConvertFrom-Json does
    # NOT enumerate a JSON array: it emits the whole Object[] as a single pipeline item.
    # So "@(... | ConvertFrom-Json)" builds a one-element array whose element is the
    # array, and $_.time inside the loop was the array of every time rather than one -
    # which is exactly the "cannot convert System.Object[] to System.DateTime" error.
    # Assigning first makes $parsed the Object[] itself, and @() around a variable that
    # already holds an array leaves it as it is.
    $parsed = $null
    try { $parsed = ($json -join '') | ConvertFrom-Json } catch { }
    $snaps = @($parsed)
    if ($snaps.Count -eq 0) {
        Write-Host ''
        Write-Host '  The repository has no snapshots yet.' -ForegroundColor Yellow
        Write-Host ''
        return
    }

    Write-Head ("Snapshots ({0})" -f $snaps.Count)
    # Sorted once and kept in an array. Sort-Object on a single item returns a scalar, and
    # indexing that with [-1] only works by PowerShell's scalar-as-array courtesy; @()
    # makes it a real array so the newest/oldest lookups below cannot surprise.
    $sorted = @($snaps | Sort-Object { [datetime]$_.time })
    $rows = $sorted | ForEach-Object {
        [pscustomobject]@{
            When  = ([datetime]$_.time).ToString('yyyy-MM-dd HH:mm')
            Id    = $_.short_id
            Host  = $_.hostname
            Tags  = ($_.tags -join ',')
            Paths = ($_.paths -join ' ')
        }
    }
    $rows | Select-Object -Last $Count | Format-Table -AutoSize |
        Out-String -Width 200 | ForEach-Object { $_.TrimEnd() } | Write-Host
    if ($snaps.Count -gt $Count) {
        Write-Host ("  ... {0} older snapshots not shown (-Count to widen)" -f ($snaps.Count - $Count)) -ForegroundColor DarkGray
    }

    # --- age of newest, which is the one number that matters
    $newest = $sorted[-1]
    $oldest = $sorted[0]
    $age = ((Get-Date) - [datetime]$newest.time)
    $acol = if ($age.TotalDays -gt 2) { 'Red' } elseif ($age.TotalDays -gt 1.2) { 'Yellow' } else { 'Green' }
    Write-Head 'Coverage'
    Write-Field 'Newest' ("{0:yyyy-MM-dd HH:mm}  ({1} ago)" -f [datetime]$newest.time, (Format-Duration $age.TotalSeconds)) $acol
    Write-Field 'Oldest' ("{0:yyyy-MM-dd HH:mm}" -f [datetime]$oldest.time)
    Write-Field 'Retention' ("{0} daily, {1} weekly, {2} monthly" -f `
        $Settings.Retention.Daily, $Settings.Retention.Weekly, $Settings.Retention.Monthly)

    # --- size
    Write-Head 'Size'
    foreach ($mode in @(@('restore-size', 'Restore size'), @('raw-data', 'Stored, deduplicated'))) {
        $st = Invoke-Restic @('stats', '--json', '--mode', $mode[0])
        if ($LASTEXITCODE -eq 0) {
            $s = try { ($st -join '') | ConvertFrom-Json } catch { $null }
            if ($s) {
                Write-Field $mode[1] ("{0}  ({1:N0} files)" -f (Format-Bytes $s.total_size), $s.total_file_count)
            }
        }
    }

    if ($Deep) {
        Write-Head 'Integrity'
        Invoke-Check -IncludeData:$false
    }
    Write-Host ''
}

# ================================================================ check

# What this proves, and what it does not: "check" verifies the repository - the index
# agrees with the pack files, nothing referenced is missing. "check -Data" additionally
# re-reads a fraction of the packs and verifies their hashes, which is what catches bit
# rot. Neither proves you can get your files back: for that see the dump technique below,
# which needs no local disk space at all.
function Invoke-Check([switch]$IncludeData) {
    # Not $args: that is an automatic variable in PowerShell.
    $checkArgs = @('check')
    if ($IncludeData) { $checkArgs += @('--read-data-subset', $Subset) }
    Write-Field 'Running' ("restic {0}" -f ($checkArgs -join ' ')) 'DarkGray'
    if ($IncludeData) {
        Write-Cont "Re-reads that fraction of the pack files. Nothing is written to disk -" 'DarkGray'
        Write-Cont 'the data is streamed and discarded - but it is downloaded.' 'DarkGray'
    } else {
        Write-Cont 'Structure only: no data is downloaded, no disk space is used.' 'DarkGray'
    }
    $out = Invoke-Restic $checkArgs
    if ($LASTEXITCODE -eq 0) {
        Write-Field 'Result' 'no errors were found' 'Green'
    } else {
        Write-Field 'Result' ("FAILED (exit {0})" -f $LASTEXITCODE) 'Red'
        $out | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
}

function Show-Check {
    Write-Host ''
    Write-Field 'Repository' $Settings.Repository
    Write-Head 'Integrity'
    Invoke-Check -IncludeData:$Data
    if (-not $Data) {
        Write-Host ''
        Write-Host '  -Data re-reads a fraction of the blobs too (catches bit rot).' -ForegroundColor DarkGray
        Write-Host "  -Subset '1/12' or -Subset '5%' sets that fraction; twelve monthly 1/12" -ForegroundColor DarkGray
        Write-Host '  runs cover everything.' -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '  Neither check proves a restore works. With no disk space to spare:' -ForegroundColor White
    Write-Host '    restic-ctl exec dump latest /etc/fstab'
    Write-Host '    restic-ctl exec dump --archive tar latest / > NUL'
    Write-Host ''
}

# ============================================================== history

function Show-History {
    $hist = Get-History
    if ($hist.Count -eq 0) {
        Write-Host ''
        Write-Host "  No run history yet ($HistoryFile)." -ForegroundColor Yellow
        Write-Host '  It is written from the first completed backup onwards.' -ForegroundColor DarkGray
        Write-Host ''
        return
    }

    Write-Head ("Run history - last {0} of {1}" -f ([math]::Min($Count, $hist.Count)), $hist.Count)
    Write-Host ''
    Write-Host ("  {0,-17} {1,-13} {2,-9} {3,-9} {4,-8} {5}" -f `
        'Finished', 'Outcome', 'Duration', 'Added', 'Snapshot', 'Files new/chg') -ForegroundColor DarkGray

    foreach ($h in @($hist | Select-Object -Last $Count)) {
        $when = try { ([datetime]$h.finishedAt).ToString('yyyy-MM-dd HH:mm') } catch { "$($h.finishedAt)" }
        $snap = if ($h.snapshotId) { $h.snapshotId.Substring(0, [math]::Min(8, $h.snapshotId.Length)) } else { '-' }
        $add  = if ($h.dataAddedBytes) { Format-Bytes $h.dataAddedBytes } else { '-' }
        $fls  = if ($null -ne $h.filesNew) { "$($h.filesNew) / $($h.filesChanged)" } else { '-' }
        Write-Host ("  {0,-17} " -f $when) -NoNewline
        Write-Host ("{0,-13} " -f $h.outcome) -NoNewline -ForegroundColor (Get-OutcomeColor $h.outcome)
        Write-Host ("{0,-9} {1,-9} {2,-8} {3}" -f (Format-Duration $h.durationSec), $add, $snap, $fls)
    }

    $bad = @($hist | Where-Object { $_.outcome -notin @('ok', 'warnings') })
    Write-Host ''
    Write-Field 'Totals' ("{0} runs, {1} failed ({2:N0}%)" -f `
        $hist.Count, $bad.Count, (100 * $bad.Count / $hist.Count)) `
        $(if ($bad.Count -gt 0) { 'Yellow' } else { 'Green' })
    Write-Host ''
}

# ================================================================== run

# "Is a backup running" is not the same question as "is restic running". Get-Process
# restic matches ANY restic: a manual "restic snapshots" in another window, this
# script's own exec subcommand, the installer's step 7. Using that alone made run
# refuse to start when nothing was backing up at all.
#   task    the scheduler says its own run is going - authoritative
#   restic  restic is running and writing backup progress
#   maybe   restic is running but writing no progress: probably another restic command
function Get-BackupInProgress {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task -and $task.State -eq 'Running') { return 'task' }
    $state = Get-RunState
    if ($state.Running -and $state.Fresh) { return 'restic' }
    if ($state.Running) { return 'maybe' }
    return $null
}

function Start-Run {
    switch (Get-BackupInProgress) {
        'task' {
            Write-Host ''
            Write-Host '  The scheduled task is already running. Showing its progress instead.' -ForegroundColor Yellow
            Watch-Run
            return
        }
        'restic' {
            Write-Host ''
            Write-Host '  A backup is already running. Showing its progress instead.' -ForegroundColor Yellow
            Watch-Run
            return
        }
        'maybe' {
            Write-Host ''
            Write-Warn 'A restic process is running, but it is not writing backup progress.'
            Write-Info 'Most likely another restic command - snapshots, check, a manual run -'
            Write-Info 'rather than a backup. Starting one now would contend for the'
            Write-Info 'repository lock and one of the two would fail.'
            Write-Host ''
            Write-Host '  See what it is:' -ForegroundColor White
            Write-Host '    Get-Process restic | Select-Object Id, StartTime, Path, CommandLine'
            Write-Host ''
            if (-not $Yes) {
                Write-Info 'Re-run with -Yes to start the backup anyway.'
                Write-Host ''
                return
            }
            Write-Info 'Starting anyway (-Yes).'
        }
    }

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Host ''
        Write-Host "  Scheduled task '$TaskName' is not registered." -ForegroundColor Red
        Write-Host '  Register it with:  Setup-ResticBackup.ps1 -From 8' -ForegroundColor Yellow
        Write-Host ''
        exit 1
    }

    # Deliberately through the scheduler, not by calling the backup script: this is the
    # only way to exercise the real run context - SYSTEM, its network credentials,
    # Tailscale unattended - instead of just the script logic.
    Write-Host ''
    Write-Field 'Starting' ("scheduled task '{0}' as {1}" -f $TaskName, $task.Principal.UserId) 'Cyan'
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 3

    if ($NoWait) {
        Write-Field 'Started' 'not waiting (-NoWait). Check with: restic-ctl.ps1 status' 'Gray'
        Write-Host ''
        return
    }
    Watch-Run
}

function Watch-Run {
    Write-Host '  Ctrl+C stops watching; the backup keeps going.' -ForegroundColor DarkGray
    Write-Host ''
    $spin = 0
    while ($true) {
        $state = Get-RunState
        # The task is considered alive while EITHER the scheduler says so or restic is
        # up. Watching only restic ended the wait during the seconds between the task
        # starting and restic spawning, and reported "no record was written".
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $taskRunning = ($task -and $task.State -eq 'Running')
        if (-not $state.Running -and -not $taskRunning) {
            # Give the script a moment to write last-run.json after restic exits.
            Start-Sleep -Seconds 3
            Write-Host "`r$(' ' * 100)`r" -NoNewline
            $last = Read-Json $LastRunFile
            if ($last) {
                Write-Field 'Finished' $last.outcome.ToUpper() (Get-OutcomeColor $last.outcome)
                Write-Cont ("took {0}, exit code {1}" -f (Format-Duration $last.durationSec), $last.exitCode)
                if ($last.snapshotId) {
                    Write-Cont ("snapshot {0}, {1} added" -f `
                        $last.snapshotId.Substring(0, [math]::Min(8, $last.snapshotId.Length)),
                        (Format-Bytes $last.dataAddedBytes))
                }
            } else {
                Write-Field 'Finished' 'restic is no longer running, no record was written' 'Yellow'
                Write-Cont 'Check the log: restic-ctl.ps1 log' 'DarkGray'
            }
            Write-Host ''
            return
        }

        $p = $state.Progress
        $chars = '|/-\'
        $tick = $chars[$spin % 4]; $spin++
        if ($p -and $state.Fresh) {
            $filled = [int]([math]::Round($p.percentDone / 5))
            $bar = '[' + ('#' * $filled) + ('.' * (20 - $filled)) + ']'
            $line = ("  {0} {1} {2,5:N1}%  {3} / {4}  ETA {5}" -f `
                $tick, $bar, $p.percentDone,
                (Format-Bytes $p.bytesDone), (Format-Bytes $p.totalBytes),
                (Format-Duration $p.secondsRemaining))
        } else {
            $line = "  $tick running - no progress data yet (scanning, or in forget/prune)"
        }
        Write-Host ("`r{0}{1}" -f $line, (' ' * [math]::Max(0, 100 - $line.Length))) -NoNewline
        Start-Sleep -Seconds 5
    }
}

# ================================================================== log

function Show-Log {
    if (-not (Test-Path $LogFile)) {
        Write-Host ''
        Write-Host "  No log yet ($LogFile)." -ForegroundColor Yellow
        Write-Host ''
        return
    }
    Write-Head ("Log - last {0} lines of {1}" -f $Count, $LogFile)
    Write-Host ''
    if ($Follow) {
        Get-Content $LogFile -Tail $Count -Wait
    } else {
        Get-Content $LogFile -Tail $Count
        Write-Host ''
        Write-Host '  -Follow keeps watching.' -ForegroundColor DarkGray
        Write-Host ''
    }
}

# =============================================================== config

function Show-Config {
    Write-Head 'Effective configuration'
    Write-Field 'Config file'   $ConfigFile
    Write-Field 'NAS'           ("{0}@{1}:{2}" -f $Config.nas.user, $Config.nas.host, $Config.nas.port)
    Write-Field 'Tools'         $(if ($Config.paths.tools) { $Config.paths.tools } else { '(not recorded)' })
    Write-Field 'Repository'    $Settings.Repository
    Write-Field 'SSH config'    $Settings.SshConfig
    Write-Field 'Host alias'    $Settings.HostAlias
    Write-Field 'Backup paths'  ($Settings.BackupPaths -join '; ')
    Write-Field 'Retention'     ("{0} daily, {1} weekly, {2} monthly" -f `
        $Settings.Retention.Daily, $Settings.Retention.Weekly, $Settings.Retention.Monthly)
    $ha = $Config.homeAssistant
    if ($ha -and $ha.host) {
        $haBox   = if ($ha.box)   { $ha.box }   else { $Config.nas.user }
        $haTopic = if ($ha.topic) { $ha.topic } else { "restic/$haBox" }
        $haUser  = if ($ha.user)  { $ha.user }  else { '<no user>' }
        $haPort  = if ($ha.port)  { $ha.port }  else { 1883 }
        Write-Field 'Home Assistant' ("{0}@{1}:{2}" -f $haUser, $ha.host, $haPort)
        Write-Field 'HA box/topic'   ("{0}  ->  {1}" -f $haBox, $haTopic)
    } else {
        Write-Field 'Home Assistant' 'not configured' 'DarkGray'
    }

    Write-Head 'Files'
    foreach ($f in @(
        @('Log',        $LogFile),
        @('Excludes',   (Join-Path $Base 'excludes.txt')),
        @('Password',   $PasswordFile),
        @('MQTT password', (Join-Path $Base 'mqtt-password')),
        @('Last run',   $LastRunFile),
        @('History',    $HistoryFile),
        @('Progress',   $ProgressFile)
    )) {
        if (Test-Path $f[1]) {
            $item = Get-Item $f[1]
            Write-Field $f[0] ("{0}   ({1:N0} KB, {2:yyyy-MM-dd HH:mm})" -f `
                $f[1], ($item.Length / 1KB), $item.LastWriteTime)
        } else {
            Write-Field $f[0] ("{0}   (absent)" -f $f[1]) 'DarkGray'
        }
    }

    Write-Head 'Exclude patterns'
    $ex = Join-Path $Base 'excludes.txt'
    if (Test-Path $ex) {
        $pat = @(Get-Content $ex | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') })
        Write-Field 'Active' ("{0} patterns" -f $pat.Count)
        $pat | ForEach-Object { Write-Host "                     $_" -ForegroundColor DarkGray }
    }
    Write-Host ''
}

# ========================================================== schedule

# These three used to be parameters of Setup-ResticBackup.ps1. They were in the wrong
# place: moving a start time meant re-running the installer, and "-Only 8 -TaskTime
# 03:30" changed the task while config.json still held the old value - drift of exactly
# the kind that made the NAS account revert on one machine.
#
# So the knobs live here, and the registration still lives in step 8 of the installer.
# One writer for the task, one command to change it.

function Get-ScheduleIntent {
    # Built with plain assignments rather than "if" inside the hashtable literal:
    # PowerShell 5.1 does not accept a statement as a hashtable value.
    $s = $null
    if ($Config.PSObject.Properties['schedule']) { $s = $Config.schedule }
    $time = $null; $limit = $null; $wake = $false
    if ($s) {
        if ($s.PSObject.Properties['time'] -and $s.time) { $time = "$($s.time)" }
        if ($s.PSObject.Properties['timeLimitHours'] -and $s.timeLimitHours) {
            $limit = [int]$s.timeLimitHours
        }
        if ($s.PSObject.Properties['wakeToRun']) { $wake = [bool]$s.wakeToRun }
    }
    return [pscustomobject]@{ Time = $time; LimitHours = $limit; Wake = $wake }
}

function Get-ScheduleRegistered {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return $null }
    $time = $null
    $trig = @($task.Triggers)[0]
    if ($trig -and $trig.StartBoundary) {
        try { $time = ([datetime]$trig.StartBoundary).ToString('HH:mm') } catch { $time = "$($trig.StartBoundary)" }
    }
    $limit = $null
    if ($task.Settings.ExecutionTimeLimit) {
        try {
            $limit = [math]::Round(
                ([System.Xml.XmlConvert]::ToTimeSpan($task.Settings.ExecutionTimeLimit)).TotalHours, 2)
        } catch { $limit = $null }
    }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    $next = $null; $last = $null; $res = $null
    if ($info) { $next = $info.NextRunTime; $last = $info.LastRunTime; $res = $info.LastTaskResult }
    return [pscustomobject]@{
        Time       = $time
        LimitHours = $limit
        Wake       = [bool]$task.Settings.WakeToRun
        State      = "$($task.State)"
        User       = $task.Principal.UserId
        NextRun    = $next
        LastRun    = $last
        LastResult = $res
    }
}

function Write-ScheduleReport {
    $intent = Get-ScheduleIntent
    $reg    = Get-ScheduleRegistered

    Write-Head 'Stored intent (config.json)'
    Write-Field 'Start time'  $(if ($intent.Time) { $intent.Time } else { '(not recorded)' })
    Write-Field 'Time limit'  $(if ($intent.LimitHours) { "$($intent.LimitHours) h" } else { '(not recorded)' })
    Write-Field 'Wake to run' $(if ($intent.Wake) { 'yes' } else { 'no' })

    Write-Head 'Registered task'
    if (-not $reg) {
        Write-Fail "no scheduled task named '$TaskName'"
        Write-Info 'Run Setup-ResticBackup.ps1 -Only 8 to register it.'
        return
    }
    Write-Field 'Start time'  $(if ($reg.Time) { $reg.Time } else { '(none)' })
    Write-Field 'Time limit'  $(if ($reg.LimitHours) { "$($reg.LimitHours) h" } else { '(none - the run is never killed)' })
    Write-Field 'Wake to run' $(if ($reg.Wake) { 'yes' } else { 'no' })
    Write-Field 'Runs as'     $reg.User
    Write-Field 'State'       $reg.State
    if ($reg.NextRun) { Write-Field 'Next run' ("{0:yyyy-MM-dd HH:mm}" -f $reg.NextRun) }
    if ($reg.LastRun -and $reg.LastRun.Year -gt 1900) {
        Write-Field 'Last run' ("{0:yyyy-MM-dd HH:mm}   result 0x{1:X}" -f $reg.LastRun, $reg.LastResult)
    }

    # The whole reason this report shows both sides.
    $diff = @()
    if ($intent.Time -and $reg.Time -and $intent.Time -ne $reg.Time) {
        $diff += "start time: config.json says $($intent.Time), the task says $($reg.Time)"
    }
    if ($intent.LimitHours -and $reg.LimitHours -and
        [math]::Abs($intent.LimitHours - $reg.LimitHours) -gt 0.01) {
        $diff += "time limit: config.json says $($intent.LimitHours) h, the task says $($reg.LimitHours) h"
    }
    if ($intent.Wake -ne $reg.Wake) {
        $diff += "wake to run: config.json says $($intent.Wake), the task says $($reg.Wake)"
    }
    Write-Host ''
    if ($diff.Count -eq 0) {
        Write-Ok 'the stored intent and the registered task agree'
    } else {
        Write-Warn 'the stored intent and the registered task disagree'
        $diff | ForEach-Object { Write-Info $_ }
        Write-Info 'Re-run "restic-ctl schedule <HH:mm>" to make the task follow config.json.'
    }
}

function Set-StoredSchedule([string]$Time, [object]$LimitHours, [object]$Wake) {
    $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    if (-not $cfg.PSObject.Properties['schedule']) {
        $cfg | Add-Member -NotePropertyName schedule -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $s = $cfg.schedule
    foreach ($pair in @(@('time', $Time), @('timeLimitHours', $LimitHours), @('wakeToRun', $Wake))) {
        $name, $value = $pair
        if ($null -eq $value) { continue }
        if ($s.PSObject.Properties[$name]) { $s.$name = $value }
        else { $s | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }
    }
    if ($cfg.PSObject.Properties['updated']) {
        $cfg.updated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    [System.IO.File]::WriteAllText($ConfigFile,
        (($cfg | ConvertTo-Json -Depth 6) + "`r`n"),
        (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Schedule {
    # Any bare argument is the new start time. Options alone (-TimeLimitHours,
    # -WakeToRun) are a change too, with the time left as it is.
    $newTime = @($Rest | Where-Object { $_ -and -not $_.StartsWith('-') } | Select-Object -First 1)[0]
    $changing = $newTime -or (Was-Given 'TimeLimitHours') -or
                (Was-Given 'WakeToRun') -or (Was-Given 'NoWakeToRun')

    if (-not $changing) {
        Write-ScheduleReport
        Write-Host ''
        Write-Info 'To change it:  restic-ctl schedule 03:30'
        Write-Info '               restic-ctl schedule -TimeLimitHours 24'
        Write-Info '               restic-ctl schedule -WakeToRun | -NoWakeToRun'
        Write-Host ''
        return
    }

    if ($WakeToRun -and $NoWakeToRun) {
        Write-Host ''
        Write-Fail '-WakeToRun and -NoWakeToRun are opposites; pass one.'
        Write-Host ''
        exit 2
    }

    if ($newTime) {
        # Validated here rather than left to New-ScheduledTaskTrigger, which accepts
        # things like "3" and quietly means three in the morning of whatever date it
        # parses. HH:mm only.
        if ($newTime -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') {
            Write-Host ''
            Write-Fail "not a time: '$newTime'"
            Write-Info 'Expected HH:mm on a 24-hour clock, e.g. 03:30 or 22:05.'
            Write-Host ''
            exit 2
        }
        # Normalised, so config.json never holds both "3:30" and "03:30".
        #
        # Not [datetime]::ParseExact with an array of formats: PowerShell binds that to
        # the single-format overload by flattening the array into "H:mm HH:mm", and then
        # every input throws "was not recognized as a valid DateTime". Found by testing
        # it, not by reading it. The regex above has already guaranteed the shape, so
        # splitting is both correct and culture-independent.
        $hm = $newTime -split ':'
        $newTime = '{0:00}:{1:00}' -f [int]$hm[0], [int]$hm[1]
    }

    $intent = Get-ScheduleIntent
    $time   = if ($newTime) { $newTime } elseif ($intent.Time) { $intent.Time } else { '13:00' }
    $limit  = if (Was-Given 'TimeLimitHours') { $TimeLimitHours }
              elseif ($intent.LimitHours) { $intent.LimitHours } else { 20 }
    $wake   = if ($NoWakeToRun) { $false } elseif ($WakeToRun) { $true } else { $intent.Wake }

    if ($limit -lt 1) {
        Write-Host ''
        Write-Fail "-TimeLimitHours $limit would have Task Scheduler kill the run immediately."
        Write-Info 'Use 20 unless you have a reason; a first backup of a large profile took 10h25m.'
        Write-Host ''
        exit 2
    }

    # The installer owns the registration. Finding it here rather than duplicating
    # 30 lines of Register-ScheduledTask means the two can never disagree.
    # Two places, so a config.json with a stale paths.tools does not stop the command:
    # what it says, then the built-in default.
    $candidates = @()
    if ($Config.paths -and $Config.paths.tools) { $candidates += $Config.paths.tools }
    $candidates += 'C:\Program Files\restic-backup'
    $installer = $null
    foreach ($c in $candidates) {
        $try = Join-Path $c 'Setup-ResticBackup.ps1'
        if (Test-Path $try) { $installer = $try; break }
    }
    if (-not $installer) {
        $installer = Join-Path $candidates[0] 'Setup-ResticBackup.ps1'
        Write-Host ''
        Write-Fail "the installer is not where config.json says it is: $installer"
        Write-Info 'Nothing has been changed. Either re-run the installer with -Update so it'
        Write-Info 'installs itself there, or apply the change by hand from your own copy:'
        Write-Info "  .\Setup-ResticBackup.ps1 -Only 8"
        Write-Host ''
        exit 1
    }

    Write-Head 'Changing the schedule'
    Write-Field 'Start time'  $(if ($intent.Time -and $intent.Time -ne $time) { "$($intent.Time)  ->  $time" } else { $time })
    Write-Field 'Time limit'  $(if ($intent.LimitHours -and $intent.LimitHours -ne $limit) { "$($intent.LimitHours) h  ->  $limit h" } else { "$limit h" })
    Write-Field 'Wake to run' $(if ($intent.Wake -ne $wake) { "$($intent.Wake)  ->  $wake" } else { "$wake" })

    Set-StoredSchedule $time $limit $wake
    Write-Ok 'config.json updated'

    Write-Head 'Re-registering the task'
    Write-Info "$installer -Only 8"
    Write-Host ''
    # Run as a child process rather than dot-sourcing: the installer has its own
    # parameters, its own $Base and its own #Requires, and none of that should land in
    # this scope. $ErrorActionPreference is lowered around it for the reason it is
    # lowered around every native call in this system: with it at Stop, anything the
    # child writes to stderr is turned into a terminating NativeCommandError, and the
    # real message is lost behind it.
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer `
            -Only 8 -Base $Base -TaskName $TaskName
        $rc = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousEap }
    if ($rc -ne 0) {
        Write-Host ''
        Write-Fail "the installer exited $rc; config.json was updated but the task may not have been"
        Write-Info 'Fix whatever it reported, then run this command again.'
        Write-Host ''
        exit 1
    }

    # Re-read both sides from disk. A step that reported success without its effect
    # being checked is the single most common bug in this whole system.
    $script:Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    Write-Host ''
    Write-ScheduleReport
    Write-Host ''
}

# ======================================================= restic passthrough

# The point of these: never retype the repository, the password file and the
# sftp.command again. They are the same restic you would run by hand, with this
# machine's connection already set up.

function Show-ResticOutput([string[]]$Lines) {
    $Lines | ForEach-Object { Write-Host "  $_" }
}

function Invoke-Exec {
    if ($Rest.Count -eq 0) {
        Write-Host ''
        Write-Host '  Usage: restic-ctl.ps1 exec <restic arguments...>' -ForegroundColor Yellow
        Write-Host '  e.g.   restic-ctl.ps1 exec snapshots --json' -ForegroundColor DarkGray
        Write-Host '         restic-ctl.ps1 exec stats latest' -ForegroundColor DarkGray
        Write-Host '         restic-ctl.ps1 exec diff 4f2a9c1b b9dd1b6d' -ForegroundColor DarkGray
        Write-Host ''
        return
    }
    Write-Host ''
    Write-Field 'Running' ("restic {0}" -f ($Rest -join ' ')) 'DarkGray'
    Write-Host ''
    Show-ResticOutput (Invoke-Restic $Rest)
    Write-Host ''
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Invoke-Forget {
    $ids   = @($Rest | Where-Object { $_ -notlike '-*' })
    $flags = @($Rest | Where-Object { $_ -like '-*' })
    $dry   = ($flags -contains '--dry-run')

    if ($ids.Count -eq 0) {
        Write-Host ''
        Write-Host '  Usage: restic-ctl.ps1 forget <snapshot-id> [<id>...] [--dry-run]' -ForegroundColor Yellow
        Write-Host ''
        Write-Info 'Removes those snapshots and prunes the data they alone referenced.'
        Write-Info 'Without --dry-run you are asked to confirm; -Yes skips the question.'
        Write-Host ''
        Write-Host '  Current snapshots:' -ForegroundColor White
        Show-ResticOutput (Invoke-Restic @('snapshots'))
        Write-Host ''
        return
    }

    $fargs = @('forget') + $ids + @('--prune') + $flags
    if ($dry) { $fargs = @('forget') + $ids + $flags }   # --prune is meaningless in a dry run

    Write-Host ''
    Write-Field 'Snapshots' ($ids -join ', ') 'White'

    if (-not $dry -and -not $Yes) {
        # Destructive and not undoable: the data of a forgotten snapshot is gone
        # once prune has run.
        Write-Host ''
        Write-Warn 'This deletes those snapshots and prunes their data. It cannot be undone.'
        Write-Info 'Run the same command with --dry-run first if you have not.'
        $answer = Read-Host "    Type the number of snapshots to remove ($($ids.Count)) to confirm"
        if ($answer -ne "$($ids.Count)") {
            Write-Host ''
            Write-Fail 'not confirmed, nothing was changed'
            Write-Host ''
            return
        }
    }

    Write-Field 'Running' ("restic {0}" -f ($fargs -join ' ')) 'DarkGray'
    Write-Host ''
    Show-ResticOutput (Invoke-Restic $fargs)
    if ($LASTEXITCODE -eq 0) {
        Write-Host ''
        Write-Field 'Result' $(if ($dry) { 'dry run, nothing was changed' } else { 'done' }) 'Green'
    } else {
        Write-Host ''
        Write-Field 'Result' ("FAILED (exit {0})" -f $LASTEXITCODE) 'Red'
    }
    Write-Host ''
}

function Invoke-Restore {
    $ids = @($Rest | Where-Object { $_ -notlike '-*' })
    $id  = if ($ids.Count -gt 0) { $ids[0] } else { 'latest' }

    if (-not $Target) {
        Write-Host ''
        Write-Host '  Usage: restic-ctl.ps1 restore [<snapshot-id>] -Target <folder>' -ForegroundColor Yellow
        Write-Host '  e.g.   restic-ctl.ps1 restore latest -Target D:\restore-test' -ForegroundColor DarkGray
        Write-Host ''
        Write-Info 'Restores into a NEW folder; it never writes over the original paths.'
        Write-Info 'Do this at least once per machine: an untested backup is a guess.'
        Write-Host ''
        return
    }
    if (Test-Path $Target) {
        $existing = @(Get-ChildItem $Target -Force -ErrorAction SilentlyContinue)
        if ($existing.Count -gt 0) {
            Write-Host ''
            Write-Fail "$Target already exists and is not empty"
            Write-Info 'Pick an empty or new folder, so a restore cannot mix with real data.'
            Write-Host ''
            return
        }
    }

    $rargs = @('restore', $id, '--target', $Target) + @($Rest | Where-Object { $_ -like '-*' })
    Write-Host ''
    Write-Field 'Snapshot' $id 'White'
    Write-Field 'Target'   $Target
    Write-Field 'Running'  ("restic {0}" -f ($rargs -join ' ')) 'DarkGray'
    Write-Host ''
    Show-ResticOutput (Invoke-Restic $rargs)
    Write-Host ''
    if ($LASTEXITCODE -eq 0) {
        Write-Field 'Result' 'restored' 'Green'
        Write-Info 'Now compare a few files against the originals before trusting it.'
    } else {
        Write-Field 'Result' ("FAILED (exit {0})" -f $LASTEXITCODE) 'Red'
    }
    Write-Host ''
}

function Invoke-Unlock {
    Write-Host ''
    Write-Field 'Running' 'restic unlock' 'DarkGray'
    Show-ResticOutput (Invoke-Restic @('unlock'))
    Write-Info 'Only locks with no live process are removed; a running backup keeps its own.'
    Write-Host ''
}

function Invoke-Ls {
    $ids = @($Rest | Where-Object { $_ -notlike '-*' })
    $id  = if ($ids.Count -gt 0) { $ids[0] } else { 'latest' }
    $rest = @($Rest | Where-Object { $_ -ne $id })
    Write-Host ''
    Write-Field 'Snapshot' $id 'White'
    Write-Host ''
    Show-ResticOutput (Invoke-Restic (@('ls', $id) + $rest))
    Write-Host ''
}

function Invoke-Find {
    if ($Rest.Count -eq 0) {
        Write-Host ''
        Write-Host '  Usage: restic-ctl.ps1 find <pattern>' -ForegroundColor Yellow
        Write-Host '  e.g.   restic-ctl.ps1 find "*.kdbx"' -ForegroundColor DarkGray
        Write-Host ''
        return
    }
    Write-Host ''
    Write-Field 'Pattern' ($Rest -join ' ') 'White'
    Write-Host ''
    Show-ResticOutput (Invoke-Restic (@('find') + $Rest))
    Write-Host ''
}

# ============================================================== publish

# Delegates to the backup script rather than carrying a second copy of the MQTT code:
# what this sends, or previews, is by construction what the scheduled run sends.
# Serves both publish and unpublish.
function Invoke-Publish([switch]$Remove) {
    $dry = $DryRun -or ($Rest -contains '--dry-run')
    $other = @($Rest | Where-Object { $_ -ne '--dry-run' })
    if ($other.Count -gt 0) {
        Write-Host "unknown option: $($other[0])" -ForegroundColor Red
        exit 2
    }

    $backupScript = Join-Path $Base 'restic-backup.ps1'
    if (-not (Test-Path $backupScript)) {
        Write-Fail "$backupScript not found - run Setup-ResticBackup.ps1"
        exit 1
    }
    # Discovery came after -Publish: a script that has -Publish but no discovery would
    # report success while Home Assistant shows no device.
    $marker = if ($Remove) { '[switch]$Unpublish' } else { '$HaDiscoveryPrefix' }
    if (-not (Select-String -Path $backupScript -SimpleMatch $marker -Quiet)) {
        Write-Host ''
        Write-Fail 'the installed restic-backup.ps1 predates this command'
        Write-Info 'Bring it up to date:  .\Setup-ResticBackup.ps1 -Update'
        Write-Info '(from the copy you brought, or from the tools folder)'
        Write-Host ''
        exit 1
    }

    $action = if ($Remove) { '-Unpublish' } else { '-Publish' }
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $backupScript, $action)
    if ($dry) { $psArgs += '-DryRun' }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& powershell.exe @psArgs 2>&1 | ForEach-Object { "$_" })
        $rc = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }

    if ($dry) {
        if ($Remove) { Write-Head 'Home Assistant removal (dry run, nothing sent)' }
        else         { Write-Head 'Home Assistant messages (dry run, nothing sent)' }
        # The first lines are "Label  value" (two or more spaces between them, the
        # label may itself contain one); the JSON after them is shown as-is.
        foreach ($line in $out) {
            if ($line -match '^([A-Z][^ ]*(?: [^ ]+)?)  +(.*)$') {
                Write-Field $Matches[1] $Matches[2]
            } else {
                Write-Host "    $line"
            }
        }
        Write-Host ''
        exit $rc
    }

    Write-Head 'Home Assistant'
    $msg = ($out | Where-Object { $_.Trim() }) -join ' '
    switch ($rc) {
        0       { Write-Ok $msg
                  if ($Remove) {
                      Write-Info 'The next backup announces it again. To retire the machine, first:'
                      Write-Info "Disable-ScheduledTask -TaskName $TaskName"
                  } }
        2       { Write-Field 'State' 'not configured' 'DarkGray'
                  Write-Info 'Enable it with: .\Setup-ResticBackup.ps1 -Only 3 -HaHost <broker> -HaUser <user>' }
        default { Write-Fail $msg
                  Write-Info 'Details in the log:  restic-ctl log' }
    }
    Write-Host ''
    exit $rc
}

# ============================================================== dispatch

if (-not (Get-Command restic.exe -ErrorAction SilentlyContinue)) {
    Write-Host 'restic.exe is not in PATH.' -ForegroundColor Red
    exit 1
}

switch ($Command) {
    'status'    { Show-Status }
    'snapshots' { Show-Snapshots }
    'run'       { Start-Run }
    'check'     { Show-Check }
    'schedule'  { Invoke-Schedule }
    'history'   { Show-History }
    'log'       { Show-Log }
    'config'    { Show-Config }
    'exec'      { Invoke-Exec }
    'forget'    { Invoke-Forget }
    'restore'   { Invoke-Restore }
    'unlock'    { Invoke-Unlock }
    'ls'        { Invoke-Ls }
    'find'      { Invoke-Find }
    'publish'   { Invoke-Publish }
    'unpublish' { Invoke-Publish -Remove }
}
