#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sets up scheduled restic backups from this Windows machine to a Synology NAS over SFTP.

.DESCRIPTION
    Runs a sequence of idempotent steps. Re-running the script is safe: every step detects
    what is already in place and skips or repairs it.

        1  Check prerequisites (admin rights, restic, ssh, ssh-keygen)
        2  Create C:\ProgramData\restic, lock it to SYSTEM + Administrators, and install
           the tools into C:\Program Files\restic-backup
        3  Write config.json, ssh\config, excludes.txt, restic-backup.ps1
        4  Generate the dedicated SSH key and the repository password
        5  Trust the NAS host key (fingerprint shown for confirmation)
        6  Verify key-based authentication  <-- stops here until the public key is on the NAS
        7  Initialise the restic repository (skipped if it already exists)
        8  Register the scheduled task running as SYSTEM
        9  Print a summary and the commands for the first backup

    Step 6 is the only manual gate: the public key has to be installed in the NAS user's
    authorized_keys. The script prints exactly what to do, then you re-run it to continue.

.PARAMETER NasHost
    Hostname or IP of the NAS. Prefer the Tailscale name on a laptop so the backup also
    works away from the LAN.

.PARAMETER NasUser
    Dedicated Synology user for this machine's backups.

.PARAMETER RepoPath
    Repository path relative to the SFTP session root, which on Synology is the virtual
    root. Default: home/restic-repo. "home" (singular) is DSM's alias for the logged-in
    account's own home; "homes" (plural) is the shared folder holding everyone's homes and
    needs a share permission a backup-only account normally lacks. Pass homes/<user>/...
    only for an account that already has a repository there.

.PARAMETER BackupPath
    One or more paths to back up. Defaults to the current user's profile folder.

.PARAMETER Port
    SSH port on the NAS. Default 22.

.PARAMETER HostAlias
    The Host entry written into ssh\config and used in the repository string.
    Default nas-restic. Machines set up earlier may use another alias; it is read
    back from config.json, so it never has to be retyped.

.PARAMETER HaHost
    Home Assistant's MQTT broker. When set, every backup publishes its outcome there,
    retained. -HaHost '' turns reporting off. Stored in config.json like the rest.

.PARAMETER HaPort
    MQTT port. Default 1883.

.PARAMETER HaUser
    MQTT account for this machine.

.PARAMETER HaPasswordFile
    Read the MQTT password from this file once and store it, ACL-locked, as
    C:\ProgramData\restic\mqtt-password. Without it an interactive run asks, so the
    password never appears on a command line or in the shell history.

.PARAMETER HaBox
    This machine's name in Home Assistant. Default: the NAS user.

.PARAMETER HaTopic
    State topic. Default: restic/<box>.

.PARAMETER Base
    Configuration directory. Default C:\ProgramData\restic.

.PARAMETER ToolsDir
    Where this machine keeps its own copy of the scripts, so a setup run from a USB
    stick does not leave the machine depending on the stick.
    Default C:\Program Files\restic-backup.

.PARAMETER TaskName
    Name of the scheduled task. Default restic-backup.

.PARAMETER From
    Start at this step number (default 1).

.PARAMETER Only
    Run just this one step. This is how restic-ctl applies a schedule change: it
    writes config.json, then calls -Only 8.

.PARAMETER SkipTask
    Do everything except registering the scheduled task.

.PARAMETER NoPath
    Do not add the tools directory to the machine PATH.

.PARAMETER AcceptChanges
    Do not ask for confirmation when a parameter would change this machine's NAS
    identity. Without it, a run that would repoint the machine at another account
    stops and asks - the drift that once sent one machine's backup to another
    machine's repository.

.PARAMETER Help
    Print the full usage, including every option and the steps, and exit.

.PARAMETER NasSetup
    Only write the NAS-side provisioning script (nas-provision-<NasUser>.sh) next to
    this one and print how to run it, then exit. Nothing local is changed. Step 4
    generates the same file as part of a normal run.

.PARAMETER Update
    Bring this machine onto the version of the scripts you are running from: install the
    tools, regenerate the generated files, re-verify. Equivalent to -From 2 with a guard
    that refuses to replace an installed copy with an older one - the mistake that the
    PATH shim makes easy, since the installed copy is the one you can type by name.

.PARAMETER Force
    Let -Update install an older version over a newer one, on purpose.

.PARAMETER ForceExcludes
    Step 3 leaves an existing excludes.txt alone, because it is meant to be tuned by
    hand. This replaces it with the current template, keeping the old one as
    excludes.txt.bak. Use it to pull new template rules onto a machine set up earlier.

.EXAMPLE
    # First run on a machine: the NAS address is asked for if omitted.
    .\Setup-ResticBackup.ps1 -NasHost nas.example.ts.net

.EXAMPLE
    # Later runs need no parameters: they come from config.json.
    .\Setup-ResticBackup.ps1 -From 3

.EXAMPLE
    .\Setup-ResticBackup.ps1 -Only 6      # re-test the SSH key after fixing the NAS side

.EXAMPLE
    # Bring a machine onto a newer copy of the scripts, from a USB stick. Run the
    # copy on the stick, not the installed one, or the guard stops you (exit 3).
    .\Setup-ResticBackup.ps1 -Update

.NOTES
    The schedule is not set here. -TaskTime, -TimeLimitHours and -WakeToRun were
    retired: they are properties of a machine already set up, and changing one should
    not mean re-running an installer. Use restic-ctl instead:

        restic-ctl schedule                     show
        restic-ctl schedule 03:30               move the start time
        restic-ctl schedule -TimeLimitHours 24
        restic-ctl schedule -WakeToRun

    It writes config.json and then calls step 8 here, so the task keeps exactly one
    writer. Passing a retired parameter prints that and exits 2.

    -Help prints the same reference as "restic-ctl help" does for the day-to-day
    commands; COMMANDS.md documents both in full.
#>
[CmdletBinding()]
param(
    # No defaults on purpose: nothing site-specific is baked into this script. Both are
    # asked for on a first run and stored in config.json, which is not in version control.
    [string]   $NasHost     = '',
    [string]   $NasUser     = '',
    [int]      $Port        = 22,
    [string]   $RepoPath,
    [string[]] $BackupPath  = @($env:USERPROFILE),
    [string]   $Base        = 'C:\ProgramData\restic',
    [string]   $ToolsDir    = 'C:\Program Files\restic-backup',
    [string]   $HostAlias   = 'nas-restic',
    [string]   $TaskName    = 'restic-backup',
    # Home Assistant reporting over MQTT; off until -HaHost is given.
    [string]   $HaHost      = '',
    [int]      $HaPort      = 1883,
    [string]   $HaUser      = '',
    [string]   $HaTopic     = '',
    [string]   $HaBox       = '',
    [string]   $HaPasswordFile = '',
    [int]      $From        = 1,
    [int]      $Only        = 0,
    [switch]   $SkipTask,
    [switch]   $NasSetup,
    [switch]   $ForceExcludes,
    [switch]   $AcceptChanges,
    [switch]   $NoPath,
    [switch]   $Update,
    [switch]   $Force,
    [switch]   $Help,

    # Retired, and kept only so that passing one says where it went instead of
    # "a parameter cannot be found". The schedule belongs to restic-ctl: changing a
    # start time should not mean re-running an installer.
    [string]   $TaskTime,
    [int]      $TimeLimitHours = 0,
    [switch]   $WakeToRun
)

$ErrorActionPreference = 'Stop'

# Bumped whenever this file changes. It exists so that -Update can tell the copy you are
# running from the copy already installed on the machine, and refuse to replace a newer
# one with an older. A hash is compared too, because a version I forgot to bump would
# otherwise hide a real difference.
$ScriptVersion = '2026.09.30.2'

# Which parameters the caller actually typed, as opposed to the ones that fell back
# to a default. This is the whole basis of the configuration handling below: a
# stored value must survive a re-run that does not mention it.
$Given = @($PSBoundParameters.Keys)
function Was-Given([string]$Name) { return $script:Given -contains $Name }

# ------------------------------------------------------------------- help

$UsageText = @'
Setup-ResticBackup.ps1 - set up scheduled restic backups from this Windows machine
to a Synology NAS over SFTP.

USAGE
  .\Setup-ResticBackup.ps1 [-NasHost <host>] [options]      first run
  .\Setup-ResticBackup.ps1 -Update                          bring onto a new version
  .\Setup-ResticBackup.ps1 -Only <n>                        re-run one step
  .\Setup-ResticBackup.ps1 -Help

  Needs an elevated shell. Re-running is safe: every step detects what is already
  in place and skips or repairs it. After the first run no parameters are needed -
  they come from C:\ProgramData\restic\config.json.

STEPS
  1  Check prerequisites (admin rights, restic, ssh, ssh-keygen)
  2  Create C:\ProgramData\restic, lock it to SYSTEM + Administrators, and install
     the tools into C:\Program Files\restic-backup so a copy run from a USB stick
     does not leave the machine depending on the stick
  3  Write config.json, ssh\config, excludes.txt, restic-backup.ps1
  4  Generate the SSH key, the repository password, and the NAS-side script
  5  Trust the NAS host key (the fingerprint is shown for confirmation)
  6  Verify authentication and write access   <-- the one manual gate
  7  Initialise the restic repository
  8  Register the scheduled task, running as SYSTEM
  9  Print the summary and the first-backup commands

  Step 6 stops until the public key is in the NAS user's authorized_keys. The
  script prints exactly what to run on the NAS, then you re-run it to continue.

WHAT TO PASS ON A FIRST RUN
  -NasHost <host>       NAS hostname or IP. No default and nothing site-specific
                        is baked in, so a first run asks if this is omitted. On a
                        laptop prefer the Tailscale name, so the backup also works
                        away from the LAN.
  -NasUser <user>       dedicated Synology account (default: restic-<hostname>)
  -Port <n>             SSH port (default 22)
  -RepoPath <path>      repository path relative to the SFTP root
                        (default home/restic-repo). "home" singular is DSM's alias
                        for the account's own home and needs no share permission;
                        "homes" plural is the shared folder and needs one a
                        backup-only account normally lacks. This distinction cost
                        an afternoon - do not change it without reason.
  -BackupPath <p>[,<p>] what to back up (default: the current user's profile)
  -HostAlias <name>     the Host entry written into ssh\config (default nas-restic)

HOME ASSISTANT (optional, any run)
  After every backup the outcome is published over MQTT, retained, to the broker
  Home Assistant uses. Off until -HaHost is given; stored like everything else.
  -HaHost <host>        MQTT broker address. -HaHost '' turns reporting off
  -HaPort <n>           MQTT port (default 1883)
  -HaUser <user>        MQTT account for this machine
  -HaPasswordFile <f>   read the MQTT password from <f> once and store it in
                        C:\ProgramData\restic\mqtt-password. Without it an
                        interactive run asks, so the password never appears on a
                        command line
  -HaBox <name>         this machine's name in Home Assistant (default: NAS user)
  -HaTopic <topic>      state topic (default: restic/<box>)
  Step 3 sends a test message, so "-Only 3 -HaHost ..." is enough to switch it on
  for a machine already set up.

OPTIONS
  -From <n>             start at step n
  -Only <n>             run just step n
  -Update               install the tools, regenerate the generated files and
                        re-verify - the same as -From 2, plus a guard that refuses
                        to replace an installed copy with an older one
  -Force                let -Update install an older version on purpose
  -ForceExcludes        step 3 leaves an existing excludes.txt alone, because it is
                        meant to be tuned by hand. This replaces it with the current
                        template, keeping the old one as excludes.txt.bak
  -AcceptChanges        do not ask for confirmation when a parameter would change
                        this machine's NAS identity
  -SkipTask             do everything except registering the scheduled task
  -NoPath               do not add the tools directory to the machine PATH
  -NasSetup             only write nas-provision-<NasUser>.sh and print how to run
                        it, then exit. Nothing local is changed
  -Base <dir>           configuration directory (default C:\ProgramData\restic)
  -ToolsDir <dir>       tools directory (default C:\Program Files\restic-backup)
  -TaskName <name>      scheduled task name (default restic-backup)
  -Help                 this text

MOVED TO restic-ctl
  The start time, the execution time limit and the wake setting are no longer
  parameters here. They are properties of a machine that is already set up, and
  changing one should not mean re-running an installer:

    restic-ctl schedule                    show
    restic-ctl schedule 03:30              move the start time
    restic-ctl schedule -TimeLimitHours 24
    restic-ctl schedule -WakeToRun

  restic-ctl writes config.json and then calls step 8 here, so the task still has
  exactly one writer.

AFTERWARDS
  restic-ctl status | snapshots | run | check | schedule | help

EXIT CODES
  0  done    1  a step failed    2  wrong usage or a missing answer
  3  -Update refused: the copy you ran is older than the installed one
'@

if ($Help) {
    Write-Host ''
    $UsageText -split "`n" | ForEach-Object {
        if ($_.Trim()) { Write-Host "  $_" } else { Write-Host '' } }
    Write-Host ''
    exit 0
}

# The three schedule parameters were removed rather than deprecated in silence: a
# parameter that is accepted and ignored is worse than one that is gone. Passing one
# now says where it went. -Only 8 still reads the schedule from config.json, which is
# how restic-ctl applies a change.
$Retired = @()
if (Was-Given 'TaskTime')       { $Retired += @('-TaskTime',       "restic-ctl schedule $TaskTime") }
if (Was-Given 'TimeLimitHours') { $Retired += @('-TimeLimitHours', "restic-ctl schedule -TimeLimitHours $TimeLimitHours") }
if (Was-Given 'WakeToRun')      { $Retired += @('-WakeToRun',      'restic-ctl schedule -WakeToRun') }
if ($Retired.Count -gt 0) {
    Write-Host ''
    for ($i = 0; $i -lt $Retired.Count; $i += 2) {
        Write-Host ("  $($Retired[$i]) is no longer a parameter of this script.") -ForegroundColor Red
        Write-Host ("  Use:  $($Retired[$i + 1])") -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '  It writes config.json and re-registers the task through step 8 here,' -ForegroundColor DarkGray
    Write-Host '  so the two can never hold different values.' -ForegroundColor DarkGray
    Write-Host ''
    exit 2
}

# First-install defaults for the schedule. They apply only when config.json has
# nothing to say; after that config.json is the source, and restic-ctl the editor.
# 20 hours, not 6: Task Scheduler KILLS the run at this limit, and a first backup with
# no parent snapshot reads and hashes everything - 10h25m on a 1 TB profile here.
$TaskTime       = '13:00'
$TimeLimitHours = 20
$WakeTask       = $false

# Paths used throughout
$SshDir       = Join-Path $Base 'ssh'
$KeyFile      = Join-Path $SshDir 'id_ed25519'
$SshConfig    = Join-Path $SshDir 'config'
$KnownHosts   = Join-Path $SshDir 'known_hosts'
$PasswordFile = Join-Path $Base 'password'
$HaPasswordStore = Join-Path $Base 'mqtt-password'
$ConfigFile   = Join-Path $Base 'config.json'
$LegacyPsd1   = Join-Path $Base 'settings.psd1'
$ExcludeFile  = Join-Path $Base 'excludes.txt'
$BackupScript = Join-Path $Base 'restic-backup.ps1'

# ------------------------------------------------- stored configuration

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content $Path -Raw | ConvertFrom-Json) } catch { return $null }
}

# Machines set up before config.json existed keep their answers in settings.psd1 plus
# ssh/config - the NAS host and user live only in the latter. Reading both means an
# existing machine never has to have its parameters retyped.
function Import-LegacySettings {
    if (-not (Test-Path $LegacyPsd1)) { return $null }
    try { $old = Import-PowerShellDataFile $LegacyPsd1 } catch { return $null }

    $alias = $old.HostAlias
    $repo  = $old.Repository        # sftp:<alias>:<repoPath>
    $path  = if ($repo -match '^sftp:[^:]+:(.*)$') { $Matches[1] } else { $null }

    # Not $host: that is an automatic variable holding the PowerShell host object.
    $nasHostName = $null; $nasUserName = $null; $nasPort = 22
    if (Test-Path $SshConfig) {
        foreach ($line in Get-Content $SshConfig) {
            if ($line -match '^\s*HostName\s+(\S+)') { $nasHostName = $Matches[1] }
            if ($line -match '^\s*User\s+(\S+)')     { $nasUserName = $Matches[1] }
            if ($line -match '^\s*Port\s+(\d+)')     { $nasPort     = [int]$Matches[1] }
        }
    }
    if (-not ($nasHostName -and $nasUserName -and $path)) { return $null }

    return [pscustomobject]@{
        nas = [pscustomobject]@{
            host = $nasHostName; user = $nasUserName; port = $nasPort
            hostAlias = $alias; repoPath = $path
        }
        backupPaths = @($old.BackupPaths)
        retention   = [pscustomobject]@{
            daily   = $old.Retention.Daily
            weekly  = $old.Retention.Weekly
            monthly = $old.Retention.Monthly
        }
        schedule = [pscustomobject]@{ time = $TaskTime; timeLimitHours = $TimeLimitHours; wakeToRun = $WakeTask }
        _migrated = $true
    }
}

$Stored = Read-JsonFile $ConfigFile
$MigratedFrom = $null
if (-not $Stored) {
    $Stored = Import-LegacySettings
    if ($Stored) { $MigratedFrom = $LegacyPsd1 }
}

# A stored value wins over a default, and loses to a parameter typed on the command
# line. Without this, re-running a single step silently reverted the machine to the
# script's defaults: on one machine "-From 3" without -NasUser repointed it at
# another machine's NAS account, which is a wrong-but-valid value that fails no check.
if ($Stored) {
    if (-not (Was-Given 'NasHost')        -and $Stored.nas.host)             { $NasHost   = $Stored.nas.host }
    if (-not (Was-Given 'NasUser')        -and $Stored.nas.user)             { $NasUser   = $Stored.nas.user }
    if (-not (Was-Given 'Port')           -and $Stored.nas.port)             { $Port      = [int]$Stored.nas.port }
    if (-not (Was-Given 'HostAlias')      -and $Stored.nas.hostAlias)        { $HostAlias = $Stored.nas.hostAlias }
    if (-not (Was-Given 'RepoPath')       -and $Stored.nas.repoPath)         { $RepoPath  = $Stored.nas.repoPath }
    if (-not (Was-Given 'BackupPath')     -and $Stored.backupPaths)          { $BackupPath = @($Stored.backupPaths) }
    if ($Stored.homeAssistant) {
        $ha = $Stored.homeAssistant
        if (-not (Was-Given 'HaHost')  -and $ha.host)  { $HaHost  = "$($ha.host)" }
        if (-not (Was-Given 'HaPort')  -and $ha.port)  { $HaPort  = [int]$ha.port }
        if (-not (Was-Given 'HaUser')  -and $ha.user)  { $HaUser  = "$($ha.user)" }
        if (-not (Was-Given 'HaTopic') -and $ha.topic) { $HaTopic = "$($ha.topic)" }
        if (-not (Was-Given 'HaBox')   -and $ha.box)   { $HaBox   = "$($ha.box)" }
    }
    # The schedule has no command-line override at all any more, so it is simply
    # whatever config.json says. restic-ctl schedule is what writes it.
    if ($Stored.schedule) {
        if ($Stored.schedule.time)           { $TaskTime       = "$($Stored.schedule.time)" }
        if ($Stored.schedule.timeLimitHours) { $TimeLimitHours = [int]$Stored.schedule.timeLimitHours }
        if ($Stored.schedule.PSObject.Properties['wakeToRun']) {
            $WakeTask = [bool]$Stored.schedule.wakeToRun
        }
    }
}

# Derived, not defaulted: one NAS account per machine, named after the machine, so
# nothing about any particular site is written into this script.
if (-not $NasUser) { $NasUser = "restic-$($env:COMPUTERNAME.ToLower())" }

# "home" (singular) is DSM's per-user alias for the logged-in account's own home,
# and it is reachable without any permission on the "homes" shared folder - which
# a backup-only account normally does not have. Going through homes/<user> instead
# fails with a bare "permission denied" even when the home's own ACL is correct.
if (-not $RepoPath) { $RepoPath = 'home/restic-repo' }

# The NAS address is the one value that can be neither derived nor sensibly defaulted,
# so a first run asks for it. Deliberate: this script carries no site-specific values,
# and the answer goes to config.json, which stays out of version control.
if (-not $NasHost) {
    if (-not [Environment]::UserInteractive) {
        Write-Host ''
        Write-Host '  No NAS address. Pass -NasHost <hostname-or-ip>.' -ForegroundColor Red
        Write-Host '  It is needed once; later runs read it from config.json.' -ForegroundColor Yellow
        exit 2
    }
    Write-Host ''
    Write-Host '  This machine has no stored configuration yet.' -ForegroundColor Cyan
    Write-Host '  The NAS address is not defaulted on purpose; it is stored after this run.' -ForegroundColor DarkGray
    Write-Host ''
    $NasHost = (Read-Host '    NAS hostname or IP').Trim()
    if (-not $NasHost) {
        Write-Host ''
        Write-Host '  Nothing entered, aborting.' -ForegroundColor Red
        exit 2
    }
}

$Repository = "sftp:${HostAlias}:${RepoPath}"

# ssh wants forward slashes in its config file; restic splits sftp.command on spaces and
# would eat backslashes as escapes, so forward slashes everywhere in the command line too.
$SshConfigFwd = $SshConfig -replace '\\', '/'
$SftpCommand  = "ssh -F $SshConfigFwd -o BatchMode=yes $HostAlias -s sftp"

# ---------------------------------------------------------------- output helpers

$script:Failed = $false

function Write-Step([int]$Number, [string]$Title) {
    Write-Host ''
    Write-Host ("[$Number] $Title") -ForegroundColor Cyan
}
function Write-Ok   ([string]$m) { Write-Host "    OK    $m" -ForegroundColor Green }
function Write-Info ([string]$m) { Write-Host "          $m" -ForegroundColor Gray }
function Write-Warn ([string]$m) { Write-Host "    WARN  $m" -ForegroundColor Yellow }
function Write-Fail ([string]$m) { Write-Host "    FAIL  $m" -ForegroundColor Red; $script:Failed = $true }

function Should-Run([int]$Number) {
    if ($Only -gt 0) { return $Number -eq $Only }
    return $Number -ge $From
}

# Writes a text file as ASCII: with '>' or the default encoding PowerShell 5.1 produces
# UTF-16, which ssh and restic cannot read.
function Write-TextFile([string]$Path, [string]$Content) {
    $dir = Split-Path $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-Content -Path $Path -Value $Content -Encoding ascii -Force
}

function Set-StrictAcl([string]$Path) {
    $isDir = Test-Path $Path -PathType Container

    # --- owner ---------------------------------------------------------------
    # Win32-OpenSSH refuses a private key unless its OWNER is the current user,
    # SYSTEM, or Administrators. The key is created by the interactive admin, so one
    # left owned by that account authenticates fine by hand and is rejected with
    # "bad permissions" once the task runs as SYSTEM - a backup that works manually
    # and fails on schedule. Administrators satisfies both cases.
    # takeown, not Set-Acl: assigning an owner other than yourself needs
    # SeRestorePrivilege, which takeown enables for itself and PowerShell does not.
    $null = Invoke-Native 'takeown' @('/F', $Path, '/A')

    # --- access rules --------------------------------------------------------
    # Built from an empty ACL rather than patched onto the existing one. Two icacls
    # behaviours make patching wrong here: "/inheritance:r" drops INHERITED entries
    # but keeps explicit ones, and "/grant:r" replaces the rights of the SIDs you
    # name without removing anybody else. Files created under C:\ProgramData get an
    # explicit entry for their creator, from the CREATOR OWNER inheritable ACE on
    # that folder, so the interactive account silently kept full control of the key
    # and ssh rejected it: "Try removing permissions for user: <domain>\<user>".
    $acl = if ($isDir) {
        New-Object System.Security.AccessControl.DirectorySecurity
    } else {
        New-Object System.Security.AccessControl.FileSecurity
    }
    $acl.SetAccessRuleProtection($true, $false)   # stop inheriting, copy nothing

    $inherit = if ($isDir) {
        [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
        [System.Security.AccessControl.InheritanceFlags]::None
    }
    # SIDs, not names, so this also works on a non-English Windows.
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {   # SYSTEM, Administrators
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            (New-Object System.Security.Principal.SecurityIdentifier($sid)),
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inherit,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)))
    }
    Set-Acl -Path $Path -AclObject $acl

    # --- verify --------------------------------------------------------------
    # Assert the result instead of trusting it: this is the step whose silent failure
    # cost two debugging sessions.
    $left = @((Get-Acl $Path).Access | Where-Object {
        $s = try {
                 $_.IdentityReference.Translate(
                     [System.Security.Principal.SecurityIdentifier]).Value
             } catch { "$($_.IdentityReference)" }
        $s -notin @('S-1-5-18', 'S-1-5-32-544')
    })
    if ($left.Count -gt 0) {
        $who = ($left | ForEach-Object { "$($_.IdentityReference)" } | Select-Object -Unique) -join ', '
        throw "ACL on $Path still grants access to: $who"
    }
}

# Runs a native command capturing stdout+stderr as plain strings.
# $ErrorActionPreference='Stop' is what we want for cmdlets, but with it a native
# command's stderr merged via 2>&1 becomes a terminating NativeCommandError: ssh
# and restic write their diagnostics there, so a failure would kill the script
# before the step could report it. Hence the local override.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
    } finally {
        $ErrorActionPreference = $previous
    }
    return $output
}

function Invoke-Restic([string[]]$ResticArgs) {
    $env:RESTIC_REPOSITORY    = $Repository
    $env:RESTIC_PASSWORD_FILE = $PasswordFile
    $env:RESTIC_CACHE_DIR     = Join-Path $Base 'cache'
    return Invoke-Native 'restic.exe' (@('-o', "sftp.command=$SftpCommand") + $ResticArgs)
}

# Emits the NAS-side provisioning script for this machine's backup account, with
# this machine's public key baked in. Everything that has to happen on the NAS
# lives there, so replicating the setup on another client is: run the Windows
# script up to step 4, then run the generated .sh on the NAS.
function Write-NasProvisionScript {
    if (-not (Test-Path "$KeyFile.pub")) {
        Write-Fail "public key not found: run steps 1-4 first (.\Setup-ResticBackup.ps1)"
        return $null
    }

    # Literal here-string with @@PLACEHOLDER@@ markers: a double-quoted one would
    # expand every $VAR of the shell script.
    $template = @'
#!/bin/sh
# ---------------------------------------------------------------------------
# Provisions the restic backup account for client "@@CLIENT@@" on this Synology
# NAS. Generated by Setup-ResticBackup.ps1 -- regenerate it rather than editing.
#
# Copy it to the NAS and run it there as a user with sudo rights:
#     sudo sh nas-provision-@@NASUSER@@.sh
#
# Idempotent: re-running changes nothing that is already correct.
# It does NOT create the DSM user; it tells you what to set if it is missing.
# ---------------------------------------------------------------------------
set -u

NAS_USER='@@NASUSER@@'
PUBKEY='@@PUBKEY@@'
REPO_PATH='@@REPOPATH@@'
HOME_DIR="/volume1/homes/$NAS_USER"
ACE="user:$NAS_USER:allow:rwxpdDaARWcCo:fd--"

fail() { echo "FAIL  $*" >&2; exit 1; }
ok()   { echo "OK    $*"; }
info() { echo "      $*"; }

[ "$(id -u)" = 0 ] || fail 'run this with sudo'

# --- 1. the DSM user must exist --------------------------------------------
if ! id "$NAS_USER" >/dev/null 2>&1; then
    echo "FAIL  DSM user \"$NAS_USER\" does not exist." >&2
    cat >&2 <<'EOF'

Create it first in DSM, Control Panel > User & Group > Create:
  - a long random password; it is never used, login is by key only
  - no membership in administrators
  - Permissions: no shared folder beyond its own home
  - Applications: deny everything; only SFTP has to work
  - User Home Service must be ON (User & Group > Advanced) so DSM creates
    the home with the right ACL

Then run this script again.
EOF
    exit 1
fi
ok "DSM user $NAS_USER exists"

# --- 2. home directory ------------------------------------------------------
[ -d /volume1/homes ] || fail 'no /volume1/homes: enable User Home Service in DSM'

if [ -d "$HOME_DIR" ]; then
    info "home exists: $HOME_DIR"
else
    mkdir "$HOME_DIR" || fail "cannot create $HOME_DIR"
    ok "created $HOME_DIR"
fi

chown "$NAS_USER:users" "$HOME_DIR" || fail "chown failed on $HOME_DIR"
# 711, not 755 or 775: sshd ignores authorized_keys when the home is writable by
# group or other, and nobody else needs to read this account's home.
chmod 711 "$HOME_DIR" || fail "chmod failed on $HOME_DIR"
ok "owner $NAS_USER:users, mode 711"

# --- 3. DSM ACL -------------------------------------------------------------
# A home created by hand stays in "Linux mode", with no ACL at all. Homes that
# DSM creates carry a full-control ACE for their owner, and restic needs it to
# create the repository directories inside the home.
if ! command -v synoacltool >/dev/null 2>&1; then
    info 'synoacltool not found, skipping the ACL step (not a Synology DSM?)'
elif synoacltool -get "$HOME_DIR" 2>&1 | grep -q "user:$NAS_USER:allow"; then
    info "ACL entry for $NAS_USER already present"
else
    synoacltool -add "$HOME_DIR" "$ACE" || fail "synoacltool -add failed on $HOME_DIR"
    ok "added ACL entry $ACE"
fi

# --- 4. authorized key ------------------------------------------------------
mkdir -p "$HOME_DIR/.ssh" || fail "cannot create $HOME_DIR/.ssh"
touch "$HOME_DIR/.ssh/authorized_keys"

if grep -qF "$PUBKEY" "$HOME_DIR/.ssh/authorized_keys" 2>/dev/null; then
    info 'public key already authorized'
else
    printf '%s\n' "$PUBKEY" >> "$HOME_DIR/.ssh/authorized_keys"
    ok 'public key appended to authorized_keys'
fi

chown -R "$NAS_USER:users" "$HOME_DIR/.ssh" || fail 'chown failed on .ssh'
chmod 700 "$HOME_DIR/.ssh"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
ok 'permissions set: .ssh 700, authorized_keys 600'

# --- 5. result --------------------------------------------------------------
echo
echo '--- home ---'
ls -ld "$HOME_DIR"
if command -v synoacltool >/dev/null 2>&1; then
    echo '--- ACL ---'
    synoacltool -get "$HOME_DIR" 2>&1 || true
fi
echo '--- authorized keys ---'
awk 'NF { n++ } END { print n " key(s)" }' "$HOME_DIR/.ssh/authorized_keys"
echo
echo "Repository will be created under $HOME_DIR"
echo "The client reaches it over SFTP as: $REPO_PATH"
echo 'Back on the client, continue with:  Setup-ResticBackup.ps1 -From 6'
'@

    $publicKey = (Get-Content "$KeyFile.pub" -Raw).Trim()
    $body = $template.Replace('@@NASUSER@@',  $NasUser).
                      Replace('@@PUBKEY@@',   $publicKey).
                      Replace('@@REPOPATH@@', $RepoPath).
                      Replace('@@CLIENT@@',   $env:COMPUTERNAME)

    # LF endings and no BOM: a shell script with CRLF fails on the NAS, and a BOM
    # breaks the shebang line.
    $body = ($body -replace "`r`n", "`n")
    $target = Join-Path $PSScriptRoot "nas-provision-$NasUser.sh"
    [System.IO.File]::WriteAllText($target, $body,
        (New-Object System.Text.UTF8Encoding($false)))
    return $target
}

# Step 8 owns the scheduled task, but config.json owns the intent. Without this, running
# "-Only 8" with a schedule option changed the task while config.json still said 13:00, and the
# next "-From 3" would quietly put the task back. Same drift as the parameters that used
# to revert, just narrower.
function Update-StoredSchedule {
    if (-not (Test-Path $ConfigFile)) { return }
    try { $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json } catch { return }
    if (-not $cfg.PSObject.Properties['schedule']) {
        $cfg | Add-Member -NotePropertyName schedule -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $sched = $cfg.schedule
    $changed = $false
    foreach ($pair in @(@('time', $TaskTime), @('timeLimitHours', $TimeLimitHours),
                        @('wakeToRun', $WakeTask))) {
        $name, $value = $pair
        if (-not $sched.PSObject.Properties[$name]) {
            $sched | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
            $changed = $true
        } elseif ("$($sched.$name)" -ne "$value") {
            $sched.$name = $value
            $changed = $true
        }
    }
    if (-not $changed) { return }
    [System.IO.File]::WriteAllText($ConfigFile,
        (($cfg | ConvertTo-Json -Depth 5) + "`r`n"),
        (New-Object System.Text.UTF8Encoding($false)))
    $wakeWord = 'no wake'
    if ($WakeTask) { $wakeWord = 'wake to run' }
    Write-Ok "config.json updated: schedule $TaskTime, time limit $TimeLimitHours h, $wakeWord"
}

# Reads the version stamp out of another copy of this script. Regex rather than running
# it: executing an unknown copy to ask its version is not a trade worth making.
function Get-StampedVersion([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $m = Select-String -Path $Path -Pattern "^\s*\`$ScriptVersion\s*=\s*'([^']+)'" |
         Select-Object -First 1
    if (-not $m) { return $null }
    return $m.Matches[0].Groups[1].Value
}

function Get-ShortHash([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.Substring(0, 12) } catch { return $null }
}

# Compares the running copy with the one installed on this machine. Step 2 copies the
# running one over the installed one, so running the installed copy by mistake - the
# obvious thing to do, since it is on PATH - would quietly reinstall an older version.
# Verdicts: none, same, newer, older, diverged.
function Compare-InstalledVersion {
    $installed = Join-Path $ToolsDir 'Setup-ResticBackup.ps1'
    $running   = $PSCommandPath
    if (-not $running) { $running = Join-Path $PSScriptRoot 'Setup-ResticBackup.ps1' }

    if ([IO.Path]::GetFullPath($running) -ieq [IO.Path]::GetFullPath($installed)) {
        return [pscustomobject]@{ Verdict = 'same'; Installed = $ScriptVersion; Running = $ScriptVersion }
    }
    if (-not (Test-Path $installed)) {
        return [pscustomobject]@{ Verdict = 'none'; Installed = $null; Running = $ScriptVersion }
    }

    $theirs = Get-StampedVersion $installed
    $result = [pscustomobject]@{
        Verdict = 'diverged'; Installed = $theirs; Running = $ScriptVersion
        InstalledPath = $installed; RunningPath = $running
    }
    if (-not $theirs) { return $result }

    if ($theirs -eq $ScriptVersion) {
        $result.Verdict = if ((Get-ShortHash $installed) -eq (Get-ShortHash $running)) { 'same' } else { 'diverged' }
        return $result
    }
    try {
        $result.Verdict = if ([version]$ScriptVersion -gt [version]$theirs) { 'newer' } else { 'older' }
    } catch { $result.Verdict = 'diverged' }
    return $result
}

function Assert-NotDowngrade {
    $c = Compare-InstalledVersion
    switch ($c.Verdict) {
        'none'  { Write-Info 'no installed copy yet: this run installs one'; return }
        'same'  { Write-Info ("version {0}, same as the installed copy" -f $c.Running); return }
        'newer' { Write-Ok ("updating the installed copy: {0} -> {1}" -f $c.Installed, $c.Running); return }
        'older' {
            Write-Host ''
            Write-Fail ("this copy is OLDER than the one installed: {0} vs {1}" -f $c.Running, $c.Installed)
            Write-Info "running   $($c.RunningPath)"
            Write-Info "installed $($c.InstalledPath)"
            Write-Host ''
            Write-Info 'Continuing would reinstall the older version. Two likely causes: you ran'
            Write-Info 'the copy on PATH instead of the one you just brought over, or the USB copy'
            Write-Info 'is stale.'
            Write-Host ''
            Write-Host '    Run the newer copy instead, or -Force to go back on purpose.' -ForegroundColor Yellow
            Write-Host ''
            if (-not $Force) { exit 3 }
            Write-Warn 'downgrading anyway (-Force)'
        }
        default {
            Write-Warn ("same version {0} but different content" -f $c.Running)
            Write-Info 'One of the two was edited. Check which one you mean to keep.'
            Write-Info "running   $($c.RunningPath)"
            Write-Info "installed $($c.InstalledPath)"
        }
    }
}

function Show-NasProvisionInstructions {
    $provision = Write-NasProvisionScript
    if (-not $provision) { return }
    $name = Split-Path $provision -Leaf

    # Each of these files carries ONE machine's public key and names ONE NAS account.
    # Running another machine's authorizes that machine on its own account and does
    # nothing here, while the failure looks identical - which has happened twice. So if a
    # stranger is sitting next to us, say so before printing the instructions.
    $others = @(Get-ChildItem (Join-Path $PSScriptRoot 'nas-provision-*.sh') -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -ne $provision })
    if ($others.Count -gt 0) {
        Write-Host ''
        Write-Warn "Other machines' provisioning scripts are in this folder:"
        foreach ($o in $others) { Write-Host ("            {0}" -f $o.Name) -ForegroundColor Yellow }
        Write-Info "Run only $name. Another machine's script authorizes that machine on its"
        Write-Info 'own NAS account and changes nothing here, while this step keeps failing'
        Write-Info 'with the same "did not accept the key".'
    }

    Write-Host ''
    Write-Host '    Everything the NAS needs is in this generated script:' -ForegroundColor Yellow
    Write-Host "      $provision"
    Write-Host ''
    Write-Host '    Copy it over and run it there, with an admin account:' -ForegroundColor White
    Write-Host "      scp `"$provision`" <admin>@${NasHost}:/tmp/$name"
    Write-Host "      ssh <admin>@$NasHost"
    Write-Host "      sudo sh /tmp/$name && rm /tmp/$name"
    Write-Host ''
    Write-Info 'It checks the DSM user, the home ownership and mode, the DSM ACL and'
    Write-Info 'authorized_keys, fixes what is wrong, and prints the final state.'
    Write-Info 'Re-running it is harmless.'
    Write-Host ''
    Write-Host "    Then: .\Setup-ResticBackup.ps1 -From 6" -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== restic backup setup ===' -ForegroundColor White
Write-Info "NAS          $NasUser@${NasHost}:$Port"
Write-Info "Repository   $Repository"
Write-Info "Local base   $Base"
Write-Info "Tools        $ToolsDir"
Write-Info "Backup paths $($BackupPath -join ', ')"
if ($HaHost) {
    $haBoxShown   = if ($HaBox) { $HaBox } else { $NasUser }
    $haTopicShown = if ($HaTopic) { $HaTopic } else { "restic/$haBoxShown" }
    $haUserShown  = if ($HaUser) { $HaUser } else { '<no user>' }
    Write-Info "Home Asst.   $haUserShown@${HaHost}:$HaPort, box $haBoxShown, topic $haTopicShown"
} else {
    Write-Info 'Home Asst.   not configured (-HaHost to enable)'
}
if ($HaPasswordFile) {
    if (-not (Test-Path $HaPasswordFile -PathType Leaf)) {
        Write-Host ''
        Write-Host "  -HaPasswordFile: cannot read $HaPasswordFile" -ForegroundColor Red
        exit 2
    }
    # Absolute now: [System.IO.File] resolves relative paths against the process
    # directory, which is not the PowerShell location the user typed it from.
    $HaPasswordFile = (Resolve-Path $HaPasswordFile).Path
}

if ($MigratedFrom) {
    Write-Info "Config       migrated from $(Split-Path $MigratedFrom -Leaf)"
} elseif ($Stored) {
    Write-Info "Config       $ConfigFile"
} else {
    Write-Info 'Config       none yet, this looks like a first run'
}

# An explicit change to any of these repoints the repository. It is not something a
# check can validate: pointing a machine at another machine's NAS account is a wrong
# but perfectly valid value, and it silently writes into the wrong repository instead
# of failing. So it is confirmed by a human, once, rather than detected afterwards.
if ($Stored) {
    $identityChanges = @()
    foreach ($t in @(
        @('NasUser',  $Stored.nas.user,     $NasUser),
        @('NasHost',  $Stored.nas.host,     $NasHost),
        @('RepoPath', $Stored.nas.repoPath, $RepoPath)
    )) {
        if ($t[1] -and "$($t[1])" -ne "$($t[2])") { $identityChanges += ,$t }
    }

    if ($identityChanges.Count -gt 0) {
        Write-Host ''
        Write-Warn 'This changes where the repository lives:'
        foreach ($c in $identityChanges) {
            Write-Host ("      {0,-10} {1}  ->  {2}" -f $c[0], $c[1], $c[2]) -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Info 'Correct when you are moving this machine to a different NAS account or'
        Write-Info 'path. Wrong if a parameter was left out by mistake: the backup would then'
        Write-Info 'write into another repository, which fails no check.'
        if ($AcceptChanges) {
            Write-Info 'Accepted via -AcceptChanges.'
        } else {
            $answer = Read-Host '    Type CHANGE to continue, anything else to abort'
            if ($answer -ne 'CHANGE') {
                Write-Host ''
                Write-Fail 'aborted, nothing was changed'
                Write-Info 'Re-run without those parameters to keep the stored values.'
                Write-Host ''
                exit 1
            }
        }
    }
}

# -Update is the ordinary way to bring a machine onto a new version of these scripts:
# install the tools, regenerate what is generated, then re-verify everything. It is
# steps 2 to 9 with the downgrade guard in front, which is the part that is easy to
# forget when the copy on PATH is the one you happen to type.
if ($Update) {
    if (-not (Was-Given 'From') -and -not (Was-Given 'Only')) { $From = 2 }
    Write-Step 0 'Update check'
    Assert-NotDowngrade
}

# Regenerate the NAS-side script and stop: nothing local is touched.
if ($NasSetup) {
    Write-Step 0 'NAS provisioning script'
    Show-NasProvisionInstructions
    Write-Host ''
    exit 0
}

# ============================================================== 1. prerequisites

if (Should-Run 1) {
    Write-Step 1 'Prerequisites'

    foreach ($exe in 'restic.exe', 'ssh.exe', 'sftp.exe', 'ssh-keygen.exe', 'ssh-keyscan.exe') {
        $cmd = Get-Command $exe -ErrorAction SilentlyContinue
        if ($cmd) { Write-Ok "$exe -> $($cmd.Source)" }
        else      { Write-Fail "$exe not found in PATH" }
    }

    if (Get-Command restic.exe -ErrorAction SilentlyContinue) {
        Write-Info ((Invoke-Native 'restic.exe' @('version')) -join ' ')
    }

    if (Get-Command tailscale.exe -ErrorAction SilentlyContinue) {
        Write-Info 'Tailscale present: make sure "Run unattended" is enabled, otherwise the'
        Write-Info 'SYSTEM task loses the tailnet when you log out.'
    } elseif ($NasHost -like '*.ts.net') {
        Write-Warn "NasHost is a Tailscale name but tailscale.exe was not found in PATH."
    }

    if ($script:Failed) {
        Write-Host ''
        Write-Host 'Install the missing tools and re-run.' -ForegroundColor Red
        Write-Info 'restic:  choco install restic'
        Write-Info 'ssh:     Settings > System > Optional features > OpenSSH Client'
        exit 1
    }
}

# =============================================================== 2. directories

if (Should-Run 2) {
    Write-Step 2 'Directory layout, permissions and tools'

    foreach ($d in $Base, $SshDir, (Join-Path $Base 'logs'), (Join-Path $Base 'cache')) {
        if (Test-Path $d) { Write-Info "exists $d" }
        else { New-Item -ItemType Directory -Force -Path $d | Out-Null; Write-Ok "created $d" }
    }

    Set-StrictAcl $Base
    Write-Ok 'ACL reset to SYSTEM + Administrators only (inheritance disabled)'

    # --- the machine gets its own copy of the tools -------------------------------
    # Running the installer from a USB stick used to leave restic-ctl on the stick, so
    # once the stick was gone the machine had no way to inspect its own backups. The
    # split follows the Windows convention: programs in Program Files, state and
    # credentials in ProgramData. Program Files keeps its inherited ACL - admins write,
    # users read - because nothing secret goes there.
    if (-not $Update) { Assert-NotDowngrade }

    if (-not (Test-Path $ToolsDir)) {
        New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
        Write-Ok "created $ToolsDir"
    }

    $copied = @()
    foreach ($name in @('Setup-ResticBackup.ps1', 'restic-ctl.ps1',
                        'RUNBOOK.md', 'README.md',
                        'setup-restic-backup.sh', 'restic-ctl.sh', 'nas-fleet-status.sh')) {
        $src = Join-Path $PSScriptRoot $name
        if (-not (Test-Path $src)) { continue }
        $dst = Join-Path $ToolsDir $name
        # Skip when already running from the destination, which would copy onto itself.
        if ([IO.Path]::GetFullPath($src) -ieq [IO.Path]::GetFullPath($dst)) { continue }
        Copy-Item $src $dst -Force
        $copied += $name
    }
    if ($copied.Count -gt 0) {
        Write-Ok ("installed: {0}" -f ($copied -join ', '))
    } else {
        Write-Info 'tools already in place (running from the installed copy)'
    }

    # A .cmd shim rather than a PowerShell function: it works from cmd, from a shortcut
    # and from Task Scheduler, and it needs no profile or execution-policy setup.
    Write-TextFile (Join-Path $ToolsDir 'restic-ctl.cmd') @"
@echo off
rem Generated by Setup-ResticBackup.ps1. Lets "restic-ctl <command>" work from any shell.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0restic-ctl.ps1" %*
"@
    Write-Ok 'restic-ctl.cmd shim'

    if ($NoPath) {
        Write-Info "-NoPath: call it as `"$ToolsDir\restic-ctl.cmd`""
    } else {
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $entries = @($machinePath -split ';' | Where-Object { $_ })
        if ($entries -notcontains $ToolsDir) {
            [Environment]::SetEnvironmentVariable('Path',
                (($entries + $ToolsDir) -join ';'), 'Machine')
            Write-Ok "added to the machine PATH: $ToolsDir"
            Write-Info 'Existing shells keep the old PATH; open a new one.'
        } else {
            Write-Info 'already on the machine PATH'
        }
        # Usable in this shell too, without waiting for a new one.
        if (($env:Path -split ';') -notcontains $ToolsDir) { $env:Path = "$env:Path;$ToolsDir" }
    }
}

# ============================================================ 3. generated files

if (Should-Run 3) {
    Write-Step 3 'Configuration files'

    # --- config.json: the one place this machine's answers live. Same schema on both
    # platforms, read by this installer, by the backup script and by restic-ctl, so
    # there is a single source of truth instead of parameters re-typed per run.
    $config = [ordered]@{
        configVersion = 1
        machine       = $env:COMPUTERNAME
        updated       = (Get-Date).ToString('o')
        nas = [ordered]@{
            host      = $NasHost
            user      = $NasUser
            port      = $Port
            hostAlias = $HostAlias
            # Relative to the SFTP session root, which on Synology is the virtual root.
            repoPath  = $RepoPath
        }
        backupPaths = @($BackupPath)
        retention   = [ordered]@{ daily = 14; weekly = 8; monthly = 12 }
        schedule    = [ordered]@{ time = $TaskTime; timeLimitHours = $TimeLimitHours; wakeToRun = $WakeTask }
        # Empty topic and box are composed by the backup script (box = NAS user,
        # topic = restic/<box>), so only what was chosen on purpose is stored.
        homeAssistant = [ordered]@{
            host  = $HaHost
            port  = $HaPort
            user  = $HaUser
            topic = $HaTopic
            box   = $HaBox
        }
        paths       = [ordered]@{ base = $Base; tools = $ToolsDir }
    }
    if ($Stored -and $Stored.retention) {
        $config.retention = [ordered]@{
            daily   = [int]$Stored.retention.daily
            weekly  = [int]$Stored.retention.weekly
            monthly = [int]$Stored.retention.monthly
        }
    }
    # UTF-8 without BOM, not the ASCII used for the other generated files: a BOM makes
    # Python's json.load fail, and this schema is deliberately shared with the Linux
    # installer, so it has to stay readable by both.
    [System.IO.File]::WriteAllText($ConfigFile,
        (($config | ConvertTo-Json -Depth 5) + "`r`n"),
        (New-Object System.Text.UTF8Encoding($false)))
    # Assert rather than assume: a config.json that does not parse would break every
    # later step and the backup script with it.
    try { $null = Get-Content $ConfigFile -Raw | ConvertFrom-Json }
    catch { throw "the config.json just written does not parse: $ConfigFile" }
    Write-Ok 'config.json'

    # The legacy file is renamed, not deleted: nothing should read it any more, and it
    # stays recoverable if the migration got something wrong.
    if (Test-Path $LegacyPsd1) {
        Move-Item $LegacyPsd1 "$LegacyPsd1.migrated" -Force
        Write-Info 'settings.psd1 migrated to config.json (kept as settings.psd1.migrated)'
    }

    # --- ssh config
    Write-TextFile $SshConfig @"
# Used only by restic. Passed explicitly with -F so it does not depend on the
# profile of whichever account runs the backup (SYSTEM, in the scheduled task).
Host $HostAlias
    HostName $NasHost
    User $NasUser
    Port $Port
    IdentityFile $($KeyFile -replace '\\', '/')
    IdentitiesOnly yes
    UserKnownHostsFile $($KnownHosts -replace '\\', '/')
    ServerAliveInterval 60
    ServerAliveCountMax 240
"@
    Write-Ok 'ssh\config'

    # --- excludes: not overwritten by default, it is meant to be hand-tuned.
    # -ForceExcludes replaces it with the current template, keeping a .bak of what
    # was there, which is how a machine picks up new template rules.
    if ((Test-Path $ExcludeFile) -and -not $ForceExcludes) {
        Write-Info 'excludes.txt already present, left untouched (-ForceExcludes to replace)'
    } else {
        if (Test-Path $ExcludeFile) {
            Copy-Item $ExcludeFile "$ExcludeFile.bak" -Force
            Write-Info "previous excludes.txt kept as excludes.txt.bak"
        }
        Write-TextFile $ExcludeFile @'
# Absolute patterns use Windows paths; bare names match at any depth.
# Check the effect with:  .\restic-backup.ps1 -DryRun

# =============================================================================
#  Virtual machine disk images
#
#  Matched by extension, not by folder, so this holds on every machine whatever
#  the VMs are called and wherever they live. The first backup of one machine
#  here showed why it matters: over 1 TB of .vhdx/.avhdx under one VM folder,
#  about 90% of the entire snapshot.
#
#  Worth excluding even with room to spare. A disk image of a running VM is
#  captured mid-write and is usually not restorable, and it changes as a whole,
#  so every run re-uploads the whole file. Back a VM up by exporting it, or from
#  inside the guest - not by copying its live disk.
# =============================================================================
*.vhd
*.vhdx
*.avhd
*.avhdx
*.vmdk
*.vdi
*.qcow2
*.hdd

# --- Downloads: re-downloadable by definition. Note the flip side: anything
# --- parked here and meant to be kept is NOT backed up.
C:\Users\*\Downloads

# --- Windows temp / caches ---
C:\Users\*\AppData\Local\Temp
C:\Users\*\AppData\Local\CrashDumps
C:\Users\*\AppData\Local\Microsoft\Windows\INetCache
C:\Users\*\AppData\Local\Microsoft\Windows\Explorer\thumbcache_*
C:\Users\*\AppData\Local\Packages\*\LocalCache
C:\Users\*\AppData\Local\Packages\*\AC\INetCache
C:\Users\*\AppData\Local\D3DSCache
C:\Users\*\AppData\Local\NVIDIA\DXCache
C:\Users\*\AppData\Local\pip\Cache

# --- Browsers ---
C:\Users\*\AppData\Local\Google\Chrome\User Data\*\Cache
C:\Users\*\AppData\Local\Google\Chrome\User Data\*\Code Cache
C:\Users\*\AppData\Local\Microsoft\Edge\User Data\*\Cache
C:\Users\*\AppData\Local\Microsoft\Edge\User Data\*\Code Cache
C:\Users\*\AppData\Local\BraveSoftware\Brave-Browser\User Data\*\Cache
C:\Users\*\AppData\Local\BraveSoftware\Brave-Browser\User Data\*\Code Cache
C:\Users\*\AppData\Local\BraveSoftware\Brave-Browser\Application\*\Installer
C:\Users\*\AppData\Local\Mozilla\Firefox\Profiles\*\cache2

# --- Re-downloadable toolchains / package caches ---
C:\Users\*\AppData\Local\Android\Sdk
C:\Users\*\.android\avd
C:\Users\*\.gradle\caches
C:\Users\*\.gradle\wrapper\dists
C:\Users\*\.m2\repository
C:\Users\*\.nuget\packages
C:\Users\*\.cargo\registry
C:\Users\*\AppData\Local\Docker
C:\Users\*\AppData\Local\npm-cache

# =============================================================================
#  Cloud-synced folders - GENERAL RULE
#
#  Anything kept in sync with a cloud service is excluded. Each service is
#  responsible for backing up its own content; restic backs up what lives only
#  on this machine. Two reasons beyond the duplication: cloud-only placeholder
#  files get downloaded one by one just to be hashed, and the same bytes would
#  otherwise be stored once per machine that syncs them.
#
#  The flip side, stated plainly: for these folders the service IS the backup.
#  A file deleted and purged there is gone, with no restic snapshot behind it.
#
#  Add new services to this list as they appear.
# =============================================================================
C:\Users\*\OneDrive
C:\Users\*\OneDrive - *
C:\Users\*\Nextcloud
C:\Users\*\Dropbox
C:\Users\*\Google Drive
C:\Users\*\GoogleDrive
C:\Users\*\iCloudDrive
C:\Users\*\Box
C:\Users\*\pCloudDrive
C:\Users\*\MEGA
C:\Users\*\Seafile
C:\Users\*\Sync
C:\Users\*\Insync

# The sync clients' own databases and caches, re-creatable either way:
C:\Users\*\AppData\Roaming\Insync\live
C:\Users\*\AppData\Local\Nextcloud
C:\Users\*\AppData\Local\Dropbox
C:\Users\*\AppData\Local\Google\DriveFS

# --- application installs that reinstall themselves on update ---
C:\Users\*\AppData\Local\Autodesk\webdeploy
C:\Users\*\AppData\Local\Programs\Microsoft VS Code
C:\Users\*\.vscode\extensions
C:\Users\*\AppData\Local\JetBrains
C:\Users\*\AppData\Local\Microsoft\WindowsApps

# --- WSL and app-bundled VM images (also caught by *.vhdx above; explicit so
# --- it is obvious they are covered) ---
C:\Users\*\AppData\Local\Packages\CanonicalGroupLimited*
C:\Users\*\AppData\Local\wsl
C:\Users\*\AppData\Local\Packages\Claude_*\LocalCache\Roaming\Claude\vm_bundles

# --- Build output inside git repos (any depth) ---
node_modules
.gradle
.cxx
__pycache__
.venv
# Generic names: fine in code trees, but they also match any folder called
# "build"/"target" elsewhere. Use absolute patterns if that is a problem.
build
target
'@
        Write-Ok 'excludes.txt'
    }

    # --- the backup script itself
    Write-TextFile $BackupScript @'
<#
  restic-backup.ps1 - scheduled restic backup to the Synology NAS over SFTP.
  Generated by Setup-ResticBackup.ps1. Edit config.json for paths and retention.

  Runs as SYSTEM from Task Scheduler; needs admin rights for VSS (--use-fs-snapshot).

    .\restic-backup.ps1            normal run (what the scheduled task does)
    .\restic-backup.ps1 -DryRun    list what would be backed up, no upload, no prune
    .\restic-backup.ps1 -Init      one-time: create the repository
    .\restic-backup.ps1 -Publish   re-send last-run.json to Home Assistant, no backup
    .\restic-backup.ps1 -Help      this text

  Prefer "restic-ctl run" over calling this by hand: it goes through the scheduler,
  so the backup runs as SYSTEM in the same context the scheduled one does. A run
  you start as yourself can succeed where the scheduled one fails.
#>
param(
    [switch]$Init,
    [switch]$DryRun,
    [switch]$Publish,
    [switch]$Help
)

if ($Help) {
    Write-Host ''
    Write-Host '  restic-backup.ps1 - the scheduled backup itself.' -ForegroundColor White
    Write-Host ''
    Write-Host '    .\restic-backup.ps1            normal run (what the scheduled task does)'
    Write-Host '    .\restic-backup.ps1 -DryRun    list what would be backed up, no upload, no prune'
    Write-Host '    .\restic-backup.ps1 -Init      one-time: create the repository'
    Write-Host '    .\restic-backup.ps1 -Publish   re-send last-run.json to Home Assistant'
    Write-Host ''
    Write-Host '  Reads everything from config.json in this folder: paths, retention,'
    Write-Host '  the NAS alias. Writes the log, progress.json, last-run.json and'
    Write-Host '  history.jsonl beside it.'
    Write-Host ''
    Write-Host '  Generated by Setup-ResticBackup.ps1 - edits here are overwritten on the' -ForegroundColor DarkGray
    Write-Host '  next -Update. Change config.json, or the installer, instead.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Day to day use restic-ctl, not this script:' -ForegroundColor DarkGray
    Write-Host '    restic-ctl run | status | snapshots | help' -ForegroundColor DarkGray
    Write-Host ''
    exit 0
}

$ErrorActionPreference = 'Continue'

$Base       = $PSScriptRoot
$ConfigFile = Join-Path $Base 'config.json'
if (-not (Test-Path $ConfigFile)) {
    Write-Error "missing $ConfigFile - run Setup-ResticBackup.ps1"
    exit 1
}
$Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

# Composed, not stored, so the repository string can never drift from its parts.
$Repository = "sftp:$($Config.nas.hostAlias):$($Config.nas.repoPath)"
$SshConfig  = (Join-Path $Base 'ssh\config') -replace '\\', '/'

$env:RESTIC_REPOSITORY    = $Repository
$env:RESTIC_PASSWORD_FILE = Join-Path $Base 'password'
$env:RESTIC_CACHE_DIR     = Join-Path $Base 'cache'

$LogFile      = Join-Path $Base 'logs\restic-backup.log'
$ProgressFile = Join-Path $Base 'progress.json'
$LastRunFile  = Join-Path $Base 'last-run.json'
$HistoryFile  = Join-Path $Base 'history.jsonl'

$CommonArgs = @('-o', "sftp.command=ssh -F $SshConfig -o BatchMode=yes $($Config.nas.hostAlias) -s sftp")
$KeepArgs   = @('--keep-daily',   "$($Config.retention.daily)",
                '--keep-weekly',  "$($Config.retention.weekly)",
                '--keep-monthly', "$($Config.retention.monthly)")

# Home Assistant reporting. Empty host = off, and a config.json written before the
# section existed simply has none. Box and topic are composed when not set, for the
# same reason as the repository string above.
$Ha = $Config.homeAssistant
$HaHost = ''; $HaPort = 1883; $HaUser = ''; $HaBox = ''; $HaTopic = ''
if ($Ha) {
    if ($Ha.host)  { $HaHost  = "$($Ha.host)" }
    if ($Ha.port)  { $HaPort  = [int]$Ha.port }
    if ($Ha.user)  { $HaUser  = "$($Ha.user)" }
    if ($Ha.box)   { $HaBox   = "$($Ha.box)" }
    if ($Ha.topic) { $HaTopic = "$($Ha.topic)" }
}
if (-not $HaBox)   { $HaBox   = "$($Config.nas.user)" }
if (-not $HaTopic) { $HaTopic = "restic/$HaBox" }
$HaPasswordFile = Join-Path $Base 'mqtt-password'

New-Item -ItemType Directory -Force -Path (Split-Path $LogFile) | Out-Null
if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 10MB)) {
    Move-Item $LogFile "$LogFile.old" -Force
}

function Write-Log([string]$Message) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message" |
        Out-File -FilePath $LogFile -Append -Encoding utf8
}

function Write-Json([string]$Path, $Object) {
    # Write then move: a reader must never catch a half-written file.
    $tmp = "$Path.tmp"
    $Object | ConvertTo-Json -Depth 6 | Set-Content -Path $tmp -Encoding utf8
    Move-Item $tmp $Path -Force
}

# last-run.json holds only the latest run, so failures would be forgotten as soon as
# the next backup succeeds. This append-only file is the run history.
function Add-History($Object) {
    ($Object | ConvertTo-Json -Depth 6 -Compress) |
        Out-File -FilePath $HistoryFile -Append -Encoding utf8
    $lines = @(Get-Content $HistoryFile -ErrorAction SilentlyContinue)
    if ($lines.Count -gt 500) {
        $lines[($lines.Count - 500)..($lines.Count - 1)] |
            Set-Content $HistoryFile -Encoding utf8
    }
}

# ---- Home Assistant over MQTT ------------------------------------------------------
# Publishes last-run.json to Home Assistant's MQTT broker, retained, so HA shows the
# latest outcome even after it restarts. Plain MQTT 3.1.1 over a TcpClient: no MQTT
# client to install on every machine, and the password is read from its locked file
# here instead of passing through a command line.
#
# Never allowed to change the backup's own result: a broker that is down is logged and
# the run exits exactly as it would have without it. Kept to Windows PowerShell 5.1,
# which is what the scheduled task runs.
function Add-MqttString([System.IO.MemoryStream]$Buffer, [string]$Text) {
    $b = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Buffer.WriteByte([byte](($b.Length -shr 8) -band 0xFF))
    $Buffer.WriteByte([byte]($b.Length -band 0xFF))
    $Buffer.Write($b, 0, $b.Length)
}

function Send-MqttPacket($Stream, [int]$Kind, [byte[]]$Body) {
    $m = New-Object System.IO.MemoryStream
    $m.WriteByte([byte]$Kind)
    $n = $Body.Length
    do {
        $digit = $n % 128
        $n = [int][math]::Floor($n / 128)
        if ($n -gt 0) { $digit = $digit -bor 0x80 }
        $m.WriteByte([byte]$digit)
    } while ($n -gt 0)
    $m.Write($Body, 0, $Body.Length)
    $bytes = $m.ToArray()
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Read-Exact($Stream, [int]$Count) {
    $buf = New-Object byte[] $Count
    $off = 0
    while ($off -lt $Count) {
        $r = $Stream.Read($buf, $off, $Count - $off)
        if ($r -le 0) { throw 'broker closed the connection' }
        $off += $r
    }
    return ,$buf
}

function Read-MqttPacket($Stream) {
    $kind = (Read-Exact $Stream 1)[0]
    $length = 0; $mult = 1
    while ($true) {
        $digit = (Read-Exact $Stream 1)[0]
        $length += ($digit -band 0x7F) * $mult
        if (-not ($digit -band 0x80)) { break }
        $mult *= 128
    }
    $body = if ($length -gt 0) { Read-Exact $Stream $length } else { ,(New-Object byte[] 0) }
    return @{ Kind = [int]$kind; Body = [byte[]]$body }
}

# Returns 0 or 1 and leaves a one-line result in $script:HaMessage, so the value the
# function returns is never mixed with text on the output pipeline.
function Send-HaStatus {
    $script:HaMessage = ''
    if (-not $HaHost) { return 0 }
    $client = $null
    try {
        if (-not $HaTopic -or $HaTopic.Contains('+') -or $HaTopic.Contains('#')) {
            throw "invalid topic '$HaTopic'"
        }
        $record = $null
        if (Test-Path $LastRunFile) {
            try { $record = Get-Content $LastRunFile -Raw | ConvertFrom-Json } catch { $record = $null }
        }
        # Nothing has run yet. Said explicitly rather than sending nothing, so HA can
        # tell a machine that never backed up from one that is not reporting.
        if (-not $record) { $record = [pscustomobject]@{ outcome = 'never'; host = $env:COMPUTERNAME } }
        $record | Add-Member -NotePropertyName box -NotePropertyValue $HaBox -Force
        $record | Add-Member -NotePropertyName publishedAt `
                             -NotePropertyValue (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz') -Force
        $payload = [System.Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 6 -Compress))

        $password = ''
        if (Test-Path $HaPasswordFile) {
            $password = ([System.IO.File]::ReadAllText($HaPasswordFile)).Trim("`r", "`n")
        }

        # 23 characters is the longest client id MQTT 3.1.1 obliges a broker to accept.
        # The box usually is the NAS account, restic-<host>, so the prefix is not doubled.
        $cid = $HaBox -replace '[^A-Za-z0-9_-]', ''
        if (-not $cid.StartsWith('restic')) { $cid = "restic-$cid" }
        if ($cid.Length -gt 23) { $cid = $cid.Substring(0, 23) }

        $flags = 0x02                                    # clean session
        $connect = New-Object System.IO.MemoryStream
        Add-MqttString $connect 'MQTT'
        $connect.WriteByte(4)                            # protocol level 3.1.1
        $tail = New-Object System.IO.MemoryStream
        Add-MqttString $tail $cid
        if ($HaUser) {
            $flags = $flags -bor 0x80
            Add-MqttString $tail $HaUser
            if ($password) {                             # 3.1.1: no password without a user
                $flags = $flags -bor 0x40
                Add-MqttString $tail $password
            }
        }
        $connect.WriteByte([byte]$flags)
        $connect.WriteByte(0); $connect.WriteByte(30)    # keep-alive, seconds
        $t = $tail.ToArray(); $connect.Write($t, 0, $t.Length)

        $client = New-Object System.Net.Sockets.TcpClient
        $pending = $client.BeginConnect($HaHost, $HaPort, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(15000)) { throw "no answer from ${HaHost}:$HaPort" }
        $client.EndConnect($pending)
        $stream = $client.GetStream()
        $stream.ReadTimeout = 15000; $stream.WriteTimeout = 15000

        Send-MqttPacket $stream 0x10 $connect.ToArray()
        $reply = Read-MqttPacket $stream
        if ($reply.Kind -ne 0x20 -or $reply.Body.Length -ne 2) {
            throw ('unexpected reply to CONNECT (0x{0:x2})' -f $reply.Kind)
        }
        $code = [int]$reply.Body[1]
        if ($code -ne 0) {
            $reasons = @{ 1 = 'protocol version refused'; 2 = 'client id refused'
                          3 = 'server unavailable'; 4 = 'bad user name or password'
                          5 = 'not authorized' }
            if ($reasons.ContainsKey($code)) { throw $reasons[$code] }
            throw "refused, code $code"
        }

        # QoS 1 + retain: the broker confirms it has the message, and keeps it.
        $pub = New-Object System.IO.MemoryStream
        Add-MqttString $pub $HaTopic
        $pub.WriteByte(0); $pub.WriteByte(1)             # packet id 1
        $pub.Write($payload, 0, $payload.Length)
        Send-MqttPacket $stream 0x33 $pub.ToArray()
        while ($true) {
            $ack = Read-MqttPacket $stream
            if ((($ack.Kind -band 0xF0) -eq 0x40) -and $ack.Body.Length -ge 2 -and
                $ack.Body[0] -eq 0 -and $ack.Body[1] -eq 1) { break }
        }
        Send-MqttPacket $stream 0xE0 ([byte[]]@())

        Write-Log "ha: published $($record.outcome) to $HaTopic on ${HaHost}:$HaPort"
        $script:HaMessage = "published to $HaTopic on ${HaHost}:$HaPort"
        return 0
    } catch {
        # .NET calls arrive wrapped ("Exception calling EndConnect ..."); the inner
        # exception is the one that says what actually happened.
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        Write-Log "ha: publish FAILED: $($e.Message)"
        $script:HaMessage = "publish failed: $($e.Message)"
        return 1
    } finally {
        if ($client) { $client.Close() }
    }
}

if ($Publish) {
    if (-not $HaHost) {
        Write-Output "Home Assistant is not configured (no homeAssistant.host in $ConfigFile)."
        exit 2
    }
    $rc = Send-HaStatus
    Write-Output $script:HaMessage
    exit $rc
}

function Invoke-Restic([string[]]$ResticArgs) {
    Write-Log ">> restic $($ResticArgs -join ' ')"
    & restic.exe @CommonArgs @ResticArgs 2>&1 |
        ForEach-Object { "$_" } |
        Out-File -FilePath $LogFile -Append -Encoding utf8
    return $LASTEXITCODE
}

# restic emits --json status objects even when its output is redirected, which is
# the only way to see progress from a scheduled run: no terminal, no progress bar.
# Status objects arrive several times a second, so they are throttled to a file
# rather than written to the log.
function Invoke-ResticBackup([string[]]$BackupArgs) {
    Write-Log ">> restic $($BackupArgs -join ' ')"
    $script:Summary = $null
    $lastProgress = [datetime]::MinValue
    $lastLogged   = [datetime]::MinValue
    $started      = Get-Date

    & restic.exe @CommonArgs @BackupArgs 2>&1 | ForEach-Object {
        $line = "$_"
        $obj = $null
        if ($line.StartsWith('{')) {
            try { $obj = $line | ConvertFrom-Json } catch { $obj = $null }
        }
        if (-not $obj) {
            if ($line.Trim()) { $line | Out-File -FilePath $LogFile -Append -Encoding utf8 }
            return
        }

        switch ($obj.message_type) {
            'status' {
                $now = Get-Date
                if (($now - $lastProgress).TotalSeconds -ge 15) {
                    $lastProgress = $now
                    Write-Json $ProgressFile ([ordered]@{
                        updated          = $now.ToString('o')
                        startedAt        = $started.ToString('o')
                        pid              = $PID
                        percentDone      = [math]::Round(($obj.percent_done * 100), 1)
                        filesDone        = $obj.files_done
                        totalFiles       = $obj.total_files
                        bytesDone        = $obj.bytes_done
                        totalBytes       = $obj.total_bytes
                        secondsElapsed   = $obj.seconds_elapsed
                        secondsRemaining = $obj.seconds_remaining
                        currentFile      = ($obj.current_files | Select-Object -First 1)
                    })
                }
                if (($now - $lastLogged).TotalMinutes -ge 5) {
                    $lastLogged = $now
                    Write-Log ("progress {0:N1}% - {1} of {2} files, {3:N1} of {4:N1} GB" -f `
                        ($obj.percent_done * 100), $obj.files_done, $obj.total_files,
                        ($obj.bytes_done / 1GB), ($obj.total_bytes / 1GB))
                }
            }
            'error' {
                Write-Log "error: $($obj.error.message) [$($obj.item)]"
            }
            'summary' {
                $script:Summary = $obj
            }
            default {
                # verbose_status and anything restic adds later
                if ($obj.action -and $obj.item) { Write-Log "$($obj.action) $($obj.item)" }
            }
        }
    }
    return $LASTEXITCODE
}

if (-not (Get-Command restic.exe -ErrorAction SilentlyContinue)) {
    Write-Log 'restic.exe not found in PATH'
    exit 1
}

if ($Init) {
    Write-Log '===== repository init ====='
    $rc = Invoke-Restic @('init')
    Write-Log "init exit code $rc"
    exit $rc
}

$runStarted = Get-Date
Write-Log ('===== backup started' + $(if ($DryRun) { ' (dry run)' } else { '' }) + ' =====')

# Ask Windows not to sleep while this runs. An idle suspend mid-backup drops the SSH
# connection and fails the run, which on a laptop is the most likely way for a backup
# to die.
#
# The Power Request API, not SetThreadExecutionState: the latter was tried first and is
# silently refused when the process runs as SYSTEM from Task Scheduler, which is exactly
# the context that matters here. PowerCreateRequest/PowerSetRequest is what Microsoft
# documents for services, and it carries a reason string that shows up in
#     powercfg /requests
# under SYSTEM, which makes it verifiable instead of hopeful.
#
# The C# is assembled from an array of lines rather than a here-string: a here-string
# terminator at column 0 would end the outer here-string this whole script is generated
# from. Also why Block returns a Win32 error code instead of a bool - if it still fails,
# the log says why.
#
# What this does NOT do: stop a lid close, or an explicit sleep from the Start menu.
# No user-space program can veto those.
$SleepBlocked = $false
try {
    Add-Type -TypeDefinition (@(
        'using System;'
        'using System.Runtime.InteropServices;'
        'public static class ResticPower {'
        '    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]'
        '    private struct ReasonContext {'
        '        public uint Version;'
        '        public uint Flags;'
        '        [MarshalAs(UnmanagedType.LPWStr)] public string Reason;'
        '    }'
        '    [DllImport("kernel32.dll", SetLastError = true)]'
        '    private static extern IntPtr PowerCreateRequest(ref ReasonContext Context);'
        '    [DllImport("kernel32.dll", SetLastError = true)]'
        '    private static extern bool PowerSetRequest(IntPtr Request, int RequestType);'
        '    [DllImport("kernel32.dll", SetLastError = true)]'
        '    private static extern bool PowerClearRequest(IntPtr Request, int RequestType);'
        '    [DllImport("kernel32.dll", SetLastError = true)]'
        '    private static extern bool CloseHandle(IntPtr handle);'
        '    // PowerRequestSystemRequired. Deliberately not DisplayRequired: the screen'
        '    // may sleep, only the machine may not.'
        '    private const int SystemRequired = 1;'
        '    private static IntPtr request = IntPtr.Zero;'
        '    public static int Block(string why) {'
        '        if (request != IntPtr.Zero) return 0;'
        '        ReasonContext c = new ReasonContext();'
        '        c.Version = 0;                 // POWER_REQUEST_CONTEXT_VERSION'
        '        c.Flags   = 1;                 // POWER_REQUEST_CONTEXT_SIMPLE_STRING'
        '        c.Reason  = why;'
        '        IntPtr h = PowerCreateRequest(ref c);'
        '        if (h == IntPtr.Zero || h == new IntPtr(-1)) return Marshal.GetLastWin32Error();'
        '        if (!PowerSetRequest(h, SystemRequired)) {'
        '            int err = Marshal.GetLastWin32Error();'
        '            CloseHandle(h);'
        '            return err;'
        '        }'
        '        request = h;'
        '        return 0;'
        '    }'
        '    public static void Release() {'
        '        if (request == IntPtr.Zero) return;'
        '        PowerClearRequest(request, SystemRequired);'
        '        CloseHandle(request);'
        '        request = IntPtr.Zero;'
        '    }'
        '}'
    ) -join "`n") -ErrorAction Stop

    $rc = [ResticPower]::Block('restic backup in progress')
    if ($rc -eq 0) {
        $SleepBlocked = $true
        Write-Log 'idle sleep blocked for the duration of this run (power request set)'
    } else {
        Write-Log "WARNING could not block idle sleep, Win32 error $rc; a suspend will interrupt this backup"
    }
} catch {
    Write-Log "WARNING could not set up the power request: $($_.Exception.Message)"
}

# Clear stale locks from an interrupted run (only removes locks with no live process)
$null = Invoke-Restic @('unlock')

$backupArgs = @('backup', '--json', '--use-fs-snapshot', '--exclude-caches',
                '--exclude-file', (Join-Path $Base 'excludes.txt'), '--tag', 'scheduled')
if ($DryRun) { $backupArgs += '--dry-run' }
$backupArgs += $Config.backupPaths

$rc = Invoke-ResticBackup $backupArgs
Remove-Item $ProgressFile -Force -ErrorAction SilentlyContinue

$outcome = switch ($rc) {
    0       { Write-Log 'backup OK'; 'ok' }
    3       { Write-Log 'backup completed with WARNINGS (some files could not be read)'; 'warnings' }
    default { Write-Log "backup FAILED (exit $rc)"; 'failed' }
}

# Recorded even on failure: the repository holds no trace of a backup that did not
# finish, so this file is the only history of failed runs.
if (-not $DryRun) {
    $record = [ordered]@{
        startedAt   = $runStarted.ToString('o')
        finishedAt  = (Get-Date).ToString('o')
        durationSec = [math]::Round(((Get-Date) - $runStarted).TotalSeconds)
        outcome     = $outcome
        exitCode    = $rc
        host        = $env:COMPUTERNAME
        runAs       = "$env:USERDOMAIN\$env:USERNAME"
    }
    if ($script:Summary) {
        $record.snapshotId          = $script:Summary.snapshot_id
        $record.filesNew            = $script:Summary.files_new
        $record.filesChanged        = $script:Summary.files_changed
        $record.dataAddedBytes      = $script:Summary.data_added
        $record.filesProcessed      = $script:Summary.total_files_processed
        $record.bytesProcessed      = $script:Summary.total_bytes_processed
        Write-Log ("summary: snapshot {0}, {1} new / {2} changed files, {3:N2} GB added" -f `
            $script:Summary.snapshot_id, $script:Summary.files_new,
            $script:Summary.files_changed, ($script:Summary.data_added / 1GB))
    }
    Write-Json $LastRunFile $record
    Add-History $record
}

if ($outcome -eq 'failed') {
    if (-not $DryRun) { $null = Send-HaStatus }
    exit $rc
}

if (-not $DryRun) {
    $rc = Invoke-Restic (@('forget', '--prune') + $KeepArgs)
    if ($rc -ne 0) {
        Write-Log "forget/prune FAILED (exit $rc)"
        $record.outcome       = 'prune-failed'
        $record.pruneExitCode = $rc
        Write-Json $LastRunFile $record
        $null = Send-HaStatus
        exit $rc
    }
    $null = Send-HaStatus
}

# Releasing the power request. Process exit would drop it anyway, so this is tidiness -
# but it also means "powercfg /requests" goes clean the moment the backup ends, which
# makes the next diagnosis honest.
if ($SleepBlocked) { [ResticPower]::Release() }

Write-Log '===== backup finished ====='
exit 0
'@
    Write-Ok 'restic-backup.ps1'

    Set-StrictAcl $Base

    # --- Home Assistant: the MQTT password and a test message ------------------
    # The password gets its own locked file, like the repository password, rather than
    # a field in config.json: config.json is shown by "restic-ctl config" and is the
    # file people copy around when comparing machines.
    if (-not $HaHost) {
        Write-Info 'Home Assistant reporting off (-HaHost to enable)'
    } else {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        if ($HaPasswordFile) {
            $pw = ([System.IO.File]::ReadAllText($HaPasswordFile)).Trim("`r", "`n")
            [System.IO.File]::WriteAllText($HaPasswordStore, $pw, $utf8)
            $pw = $null
            Write-Ok "MQTT password stored in $HaPasswordStore"
        } elseif (Test-Path $HaPasswordStore) {
            Write-Info 'MQTT password already present, kept (-HaPasswordFile to replace)'
        } elseif ($HaUser -and [Environment]::UserInteractive) {
            $secure = Read-Host "    MQTT password for $HaUser (empty for none)" -AsSecureString
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try { $pw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            if ($pw) {
                [System.IO.File]::WriteAllText($HaPasswordStore, $pw, $utf8)
                Write-Ok "MQTT password stored in $HaPasswordStore"
            }
            $pw = $null
        } elseif ($HaUser) {
            Write-Warn 'no MQTT password stored and no console to ask: pass -HaPasswordFile'
        }
        if (Test-Path $HaPasswordStore) { Set-StrictAcl $HaPasswordStore }

        # Sent now rather than discovered wrong at 3 a.m.: a bad password or an
        # unreachable broker shows here, while someone is looking. It republishes the
        # last run, or "never" on a new machine - both true statements.
        $out = Invoke-Native 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass',
                                                '-File', $BackupScript, '-Publish')
        $msg = (@($out) | Where-Object { "$_".Trim() }) -join ' '
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Home Assistant: $msg"
        } else {
            Write-Warn "Home Assistant: $msg"
            Write-Info 'The backup itself is not affected; it only stops reporting. Fix it'
            Write-Info "and re-run with -Only 3, or test with: $BackupScript -Publish"
        }
    }
}

# ====================================================== 4. key and repo password

if (Should-Run 4) {
    Write-Step 4 'SSH key, repository password and NAS provisioning script'

    if (Test-Path $KeyFile) {
        Write-Info 'private key already present, kept'
    } else {
        # Via cmd.exe: PowerShell 5.1 drops an empty-string argument, so -N '' would make
        # ssh-keygen prompt for a passphrase instead of creating a passphrase-less key.
        $null = Invoke-Native 'cmd.exe' @('/c',
            "ssh-keygen -t ed25519 -q -N `"`" -C `"restic@$env:COMPUTERNAME`" -f `"$KeyFile`"")
        if (-not (Test-Path $KeyFile)) { Write-Fail 'ssh-keygen did not create the key'; exit 1 }
        Write-Ok 'ed25519 key generated (no passphrase: the task runs unattended)'
    }
    Set-StrictAcl $KeyFile
    Write-Ok 'key owner and ACL: Administrators + SYSTEM only'
    Set-StrictAcl "$KeyFile.pub"

    if (Test-Path $PasswordFile) {
        Write-Info 'repository password already present, kept'
    } else {
        $bytes = [byte[]]::new(32)
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        Set-Content -Path $PasswordFile -Value ([Convert]::ToBase64String($bytes)) `
                    -NoNewline -Encoding ascii
        Write-Ok 'repository password generated'
        Write-Host ''
        Write-Warn 'Copy this password into your password manager NOW.'
        Write-Warn 'Without it the repository is unrecoverable, backups included.'
        Write-Host "          $(Get-Content $PasswordFile -Raw)" -ForegroundColor White
    }
    # Outside the else on purpose: an existing password file still needs its ACL
    # asserted, and previously it was only set on the run that created it.
    Set-StrictAcl $PasswordFile

    $provisionScript = Write-NasProvisionScript
    if ($provisionScript) {
        Write-Ok "NAS provisioning script: $provisionScript"
        Write-Info 'Everything that has to happen on the NAS is in there. Copy it over and'
        Write-Info 'run it as an admin user with sudo, then come back to step 6.'
    }
}

# ============================================================== 5. host key trust

if (Should-Run 5) {
    Write-Step 5 'NAS host key'

    # Every ssh-* call goes through Invoke-Native. These tools write banners and
    # diagnostics to stderr even on success, and with $ErrorActionPreference='Stop' a
    # native command's stderr raises a terminating NativeCommandError - which "2>$null"
    # does NOT prevent, because the error record is created before the redirection
    # discards the text. Invoke-Native lowers the preference for the call and hands the
    # merged output back as plain strings, so comment lines are filtered out here.
    $needScan = $true
    if (Test-Path $KnownHosts) {
        $found = @(Invoke-Native 'ssh-keygen.exe' @('-F', $NasHost, '-f', $KnownHosts) |
                   Where-Object { $_ -and -not $_.TrimStart().StartsWith('#') })
        if ($found.Count -gt 0) {
            Write-Info "host key for $NasHost already trusted"
            $needScan = $false
        } else {
            Write-Info "no host key for $NasHost in $KnownHosts yet"
        }
    }

    if ($needScan) {
        # ssh-keyscan announces itself on stderr ("# host:22 SSH-2.0-OpenSSH_x.y"), so
        # only the non-comment lines are the actual key.
        $scan = @(Invoke-Native 'ssh-keyscan.exe' @('-p', "$Port", '-t', 'ed25519', $NasHost) |
                  Where-Object { $_ -and -not $_.TrimStart().StartsWith('#') })
        if ($scan.Count -eq 0) {
            Write-Fail "ssh-keyscan got no key from ${NasHost}:$Port"
            Write-Info 'Is the NAS reachable under that name? For a Tailscale name, is the'
            Write-Info 'tailnet up?'
            exit 1
        }

        $tmp = New-TemporaryFile
        Set-Content -Path $tmp -Value $scan -Encoding ascii
        $fingerprint = (Invoke-Native 'ssh-keygen.exe' @('-lf', "$tmp")) -join ' '
        Remove-Item $tmp -Force

        Write-Host ''
        Write-Host "    Host key fingerprint: $fingerprint" -ForegroundColor White
        Write-Info 'Check it against DSM > Control Panel > Terminal & SNMP, or against the'
        Write-Info 'known_hosts of a machine that already talks to this NAS.'
        $answer = Read-Host '    Trust this key? (yes/no)'
        if ($answer -ne 'yes') { Write-Fail 'host key not trusted, aborting'; exit 1 }

        Add-Content -Path $KnownHosts -Value $scan -Encoding ascii
        Set-StrictAcl $KnownHosts
        Write-Ok "host key stored in $KnownHosts"
    }
}

# ========================================================= 6. authentication test

if (Should-Run 6) {
    Write-Step 6 'Key-based authentication'

    # Tested with the sftp client, NOT with "ssh -s sftp": on a successful login the
    # latter hands the session to the SFTP subsystem and waits on stdin forever, so a
    # working setup would hang here. A batch file makes sftp connect, run one command
    # and exit with a usable exit code - and it exercises the same subsystem restic uses.
    $batchFile = Join-Path $env:TEMP "restic-sftp-test-$PID.txt"
    Set-Content -Path $batchFile -Value 'pwd' -Encoding ascii
    try {
        $out = Invoke-Native 'sftp.exe' @('-F', $SshConfig, '-o', 'BatchMode=yes',
                                         '-o', 'ConnectTimeout=15', '-b', $batchFile, $HostAlias)
        $authOk = ($LASTEXITCODE -eq 0)
    } finally {
        Remove-Item $batchFile -Force -ErrorAction SilentlyContinue
    }

    if ($authOk) {
        Write-Ok "authenticated as $NasUser@$NasHost with the dedicated key"
        $remotePwd = $out | Where-Object { $_ -match 'working directory' } | Select-Object -First 1
        if ($remotePwd) {
            Write-Info $remotePwd.Trim()
            Write-Info "The repository path is relative to this: $RepoPath"
        }

        # Write probe. Without it, a home the user cannot write into surfaces only later as
        # a bare "MkdirAll ...: permission denied" from restic init. Typical cause: the home
        # was created by root with mkdir -p instead of by DSM's User Home Service, so it
        # stayed owned by root even though authorized_keys inside it is correct.
        $repoParent = $RepoPath -replace '/[^/]+/?$', ''
        if (-not $repoParent) { $repoParent = '.' }
        $probe = "$repoParent/.restic-write-probe"

        $batchFile = Join-Path $env:TEMP "restic-sftp-probe-$PID.txt"
        Set-Content -Path $batchFile -Value @("mkdir $probe", "rmdir $probe") -Encoding ascii
        try {
            $out = Invoke-Native 'sftp.exe' @('-F', $SshConfig, '-o', 'BatchMode=yes',
                                             '-b', $batchFile, $HostAlias)
            $writeOk = ($LASTEXITCODE -eq 0)
        } finally {
            Remove-Item $batchFile -Force -ErrorAction SilentlyContinue
        }

        if ($writeOk) {
            Write-Ok "write access confirmed under $repoParent"
        } else {
            Write-Host ''
            Write-Fail "authentication works, but $NasUser cannot create directories under $repoParent"
            Write-Info ($out -join ' ')
            Write-Host ''
            Write-Info 'The account can log in but not write in its own home. Usually the home'
            Write-Info 'was created by hand rather than by DSM, so it has no ACL at all'
            Write-Info '("Linux mode") while DSM-created homes carry an owner ACE.'
            Show-NasProvisionInstructions
            exit 1
        }
    } else {
        Write-Host ''
        Write-Fail 'the NAS did not accept the key'
        Write-Info ($out -join ' ')
        Write-Host ''
        Write-Info 'sshd also refuses the key silently when the home, .ssh or authorized_keys'
        Write-Info 'are writable by group or other, so check the reported permissions.'
        Show-NasProvisionInstructions
        exit 1
    }
}

# ============================================================ 7. repository init

if (Should-Run 7) {
    Write-Step 7 'restic repository'

    $null = Invoke-Restic @('cat', 'config')
    if ($LASTEXITCODE -eq 0) {
        Write-Info 'repository already initialised'
    } else {
        $out = Invoke-Restic @('init')
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "repository created at $Repository"
        } else {
            Write-Fail 'restic init failed'
            Write-Info ($out -join ' ')
            exit 1
        }
    }
}

# ============================================================ 8. scheduled task

if ((Should-Run 8) -and -not $SkipTask) {
    Write-Step 8 'Scheduled task'

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
              -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$BackupScript`""
    $trigger = New-ScheduledTaskTrigger -Daily -At $TaskTime
    # 20 hours, not 6: Task Scheduler KILLS the task at this limit, and a first backup
    # with no parent snapshot reads and hashes everything. On a 1 TB profile that took
    # 10h25m, so a 6-hour limit would have terminated it halfway. The same happens on
    # any later run that has to re-read in bulk, e.g. after the local cache is lost.
    #
    # Battery: the two "AllowStartIfOnBatteries"/"DontStopIfGoingOnBatteries" switches
    # were here and are deliberately gone. Their absence restores the Task Scheduler
    # defaults - do not start on battery, stop if the machine goes on battery - which is
    # what a laptop wants. Stopping mid-run costs almost nothing: restic keeps the packs
    # it has already uploaded, so the next run resumes rather than restarting.
    #
    # RestartCount: a suspend mid-backup drops the SSH connection and the run exits
    # non-zero, which Task Scheduler sees as a failure. These retries are what turn an
    # interrupted backup into a completed one without waiting for tomorrow.
    $settingsArgs = @{
        StartWhenAvailable        = $true
        RunOnlyIfNetworkAvailable = $true
        ExecutionTimeLimit        = (New-TimeSpan -Hours $TimeLimitHours)
        RestartCount              = 3
        RestartInterval           = (New-TimeSpan -Minutes 30)
    }
    # Opt-in: waking a laptop that is on battery only to skip the backup is pointless,
    # while on a desktop that sleeps it is exactly what you want.
    if ($WakeTask) { $settingsArgs['WakeToRun'] = $true }
    $settings = New-ScheduledTaskSettingsSet @settingsArgs

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -User 'SYSTEM' -RunLevel Highest -Force | Out-Null

    Write-Ok "task '$TaskName' registered as SYSTEM, daily at $TaskTime"
    Write-Info '-StartWhenAvailable is the equivalent of systemd Persistent=true: if the PC'
    Write-Info 'was off at that time, the backup runs as soon as it can.'
    Write-Info "Time limit $TimeLimitHours h: Task Scheduler kills the run at that point."
    Write-Info 'On battery: does not start, and stops if the machine is unplugged.'
    Write-Info 'On failure: retries 3 times, 30 minutes apart, which covers a suspend.'
    if ($WakeTask) {
        Write-Info 'WakeToRun: wakes the machine at the scheduled time.'
    } else {
        Write-Info "Not waking the machine. 'restic-ctl schedule -WakeToRun' turns that on."
    }
    Update-StoredSchedule
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($info -and $info.NextRunTime) {
        Write-Info ("next run: {0:yyyy-MM-dd HH:mm}" -f $info.NextRunTime)
    }
}

# ==================================================================== 9. summary

if (Should-Run 9) {
    Write-Step 9 'Next steps'

    Write-Host ''
    Write-Host '    Review the exclude patterns, then dry-run before the first real backup:' -ForegroundColor White
    Write-Host "      notepad $ExcludeFile"
    Write-Host "      & '$BackupScript' -DryRun"
    Write-Host "      Get-Content '$Base\logs\restic-backup.log' -Tail 50"
    Write-Host ''
    Write-Host '    First real backup (it will take a while):' -ForegroundColor White
    Write-Host "      & '$BackupScript'"
    Write-Host ''
    Write-Host '    Check the snapshots:' -ForegroundColor White
    Write-Host "      `$env:RESTIC_REPOSITORY='$Repository'"
    Write-Host "      `$env:RESTIC_PASSWORD_FILE='$PasswordFile'"
    Write-Host "      restic -o `"sftp.command=$SftpCommand`" snapshots"
    Write-Host ''
    Write-Host '    Test the scheduled task end to end:' -ForegroundColor White
    Write-Host "      Start-ScheduledTask $TaskName"
    Write-Host "      Get-ScheduledTaskInfo $TaskName"
    Write-Host ''
    if ($NasHost -like '*.ts.net') {
        Write-Warn 'Tailscale must be in "Run unattended" mode, or the SYSTEM task will not'
        Write-Warn 'reach the NAS once you log out.'
    } else {
        Write-Warn "NasHost is ${NasHost}: the backup only works on that network. On a laptop,"
        Write-Warn 're-run with -NasHost <name>.ts.net and -From 3 to switch to Tailscale.'
    }
}

Write-Host ''
