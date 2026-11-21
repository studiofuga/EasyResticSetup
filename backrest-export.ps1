#Requires -Version 5.1
<#
.SYNOPSIS
  Build a Backrest config.json from the existing restic-backup configuration.

.DESCRIPTION
  Reads config.json, excludes.txt and the NAS settings written by
  Setup-ResticBackup.ps1 and produces an equivalent Backrest configuration.

  No secret is copied. The repository password is referenced through
  RESTIC_PASSWORD_FILE, and SSH goes through the existing ssh\config.
  The output is written outside this folder by default, so it cannot be
  committed by accident.

  Run it elevated: the generated plan uses --use-fs-snapshot (VSS), as the
  scheduled task does.

.EXAMPLE
  .\backrest-export.ps1                 # writes C:\ProgramData\backrest\config.json
  .\backrest-export.ps1 -Stdout         # print the JSON, write nothing
  .\backrest-export.ps1 -Out D:\bk\config.json -Force
#>
[CmdletBinding()]
param(
    [string]$Base = 'C:\ProgramData\restic',
    [string]$Out  = 'C:\ProgramData\backrest\config.json',
    [string]$Instance = '',
    [switch]$Stdout,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$configFile  = Join-Path $Base 'config.json'
$excludeFile = Join-Path $Base 'excludes.txt'
$passFile    = Join-Path $Base 'password'
$sshConfig   = (Join-Path $Base 'ssh\config') -replace '\\', '/'
$manifestDir = Join-Path $Base 'manifest'
$cacheDir    = Join-Path $Base 'cache'

if (-not (Test-Path $configFile)) { throw "missing $configFile - run Setup-ResticBackup.ps1 first" }
if (-not (Test-Path $passFile))   { throw "missing $passFile" }

$cfg = Get-Content $configFile -Raw | ConvertFrom-Json

# Repository string: the same composition restic-backup.ps1 uses.
$alias   = [string]$cfg.nas.hostAlias
$repoUri = "sftp:${alias}:$($cfg.nas.repoPath)"
$repoId  = if ($alias) { $alias } else { 'nas-restic' }

# Backup paths, plus the manifest folder when no configured path already covers it
# (same rule as Get-RunPaths in restic-backup.ps1).
$paths = @($cfg.backupPaths)
$covered = $false
foreach ($p in $paths) {
    $prefix = ("$p".TrimEnd('\') + '\')
    if (($manifestDir + '\').StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $covered = $true }
}
if (-not $covered) { $paths += $manifestDir }

# Excludes: one restic pattern per line; comments and blank lines are dropped.
$excludes = @()
if (Test-Path $excludeFile) {
    $excludes = @(Get-Content $excludeFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') })
}

# Schedule: "HH:mm" becomes a five-field cron expression.
$time = if ($cfg.schedule.time) { [string]$cfg.schedule.time } else { '13:00' }
if ($time -notmatch '^(\d{1,2}):(\d{2})$') { throw "schedule.time must be HH:mm, got '$time'" }
$cron = '{0} {1} * * *' -f [int]$Matches[2], [int]$Matches[1]

$ret = $cfg.retention
$instanceId = if ($Instance) { $Instance } else { [string]$cfg.machine }

$backrest = [ordered]@{
    version  = 4
    instance = $instanceId
    repos    = @(
        [ordered]@{
            id    = $repoId
            uri   = $repoUri
            env   = @(
                "RESTIC_PASSWORD_FILE=$passFile",
                "RESTIC_CACHE_DIR=$cacheDir"
            )
            flags = @('-o', "sftp.command=ssh -F $sshConfig -o BatchMode=yes $alias -s sftp")
        }
    )
    plans    = @(
        [ordered]@{
            id          = "backup-$repoId"
            repo        = $repoId
            paths       = @($paths)
            excludes    = @($excludes)
            schedule    = [ordered]@{ clock = 'CLOCK_LOCAL'; cron = $cron }
            retention   = [ordered]@{
                policyTimeBucketed = [ordered]@{
                    daily   = [int]$ret.daily
                    weekly  = [int]$ret.weekly
                    monthly = [int]$ret.monthly
                }
            }
            backupFlags = @('--use-fs-snapshot')
        }
    )
}

$json = ConvertTo-Json -InputObject $backrest -Depth 8

if ($Stdout) { $json; return }

if ((Test-Path $Out) -and -not $Force) {
    throw "$Out already exists. Stop Backrest, then rerun with -Force."
}
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
[System.IO.File]::WriteAllText($Out, $json + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host "written: $Out"
Write-Host 'Check the generated file against the config Backrest creates on first start.'
