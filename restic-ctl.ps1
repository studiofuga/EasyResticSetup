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
      history     table of recent runs, including failed ones
      log         tail the backup log
      config      the effective settings of this machine

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

    Reads C:\ProgramData\restic\settings.psd1, so it needs no configuration of its
    own. Most subcommands need an elevated shell, because the credentials are
    readable by SYSTEM and Administrators only.

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
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'snapshots', 'run', 'check', 'history', 'log', 'config',
                 'exec', 'forget', 'restore', 'unlock', 'ls', 'find')]
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

    # Everything not bound above, passed through to restic. This is what makes
    # the wrapper subcommands work without re-declaring each restic option.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Rest = @()
)

$ErrorActionPreference = 'Stop'

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

    Write-Head 'Files'
    foreach ($f in @(
        @('Log',        $LogFile),
        @('Excludes',   (Join-Path $Base 'excludes.txt')),
        @('Password',   $PasswordFile),
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
    'history'   { Show-History }
    'log'       { Show-Log }
    'config'    { Show-Config }
    'exec'      { Invoke-Exec }
    'forget'    { Invoke-Forget }
    'restore'   { Invoke-Restore }
    'unlock'    { Invoke-Unlock }
    'ls'        { Invoke-Ls }
    'find'      { Invoke-Find }
}
