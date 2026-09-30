#!/bin/bash
# =============================================================================
#  restic-ctl - inspect and control the restic backup on this machine.
#
#  Linux counterpart of restic-ctl.ps1, same subcommands:
#
#    status      is a backup running, how did the last one go, what does the
#                timer think, how many runs failed recently
#    snapshots   what the repository holds: snapshots, age of the newest, totals
#    run         start a backup THROUGH SYSTEMD, in the same context the timer
#                uses, and follow it
#    check       verify repository integrity
#    schedule    show or change when the backup runs
#    history     table of recent runs, including failed ones
#    log         tail the backup log
#    config      the effective settings of this machine
#    publish     send the last result to Home Assistant now (--dry-run: show it)
#    unpublish   remove this machine from Home Assistant
#    help        the command list, or the detail for one command
#
#  And, as a wrapper over restic itself, so the repository, the password file
#  and the sftp.command never have to be retyped:
#
#    exec        run any restic command against this repository
#    forget      remove snapshots and prune, with a confirmation step
#    restore     restore a snapshot into a new folder
#    ls          list a snapshot's contents
#    find        find a path across snapshots
#    unlock      clear stale locks
#
#  Fast by default: status, snapshots and history read local files and repository
#  metadata only. --deep adds a restic check; check --data re-reads actual data.
#
#  Reads /etc/restic/config.json, so it needs no configuration of its own, and
#  must run as root because the credentials are root-only.
#
#    sudo restic-ctl status
#    sudo restic-ctl run
#    sudo restic-ctl snapshots --deep
#    sudo restic-ctl check --data
# =============================================================================
set -u

BASE='/etc/restic'
SERVICE='restic-backup.service'
TIMER='restic-backup.timer'
COUNT=15
DEEP=0
DATA=0
FOLLOW=0
NOWAIT=0
CMD='status'
YES=0
TARGET=''
REST=''
# Fraction of the data blobs that "check --data" re-reads. 1/12 means twelve monthly
# runs cover the whole repository, which is how to get full verification on a link that
# cannot afford downloading everything at once.
SUBSET='1/12'

RETRY=''
PUB_DRY=0

# ------------------------------------------------------------------- help
#
# Deliberately not "sed -n '3,26p' $0" any more: that printed the header comment and
# nothing about the options, which is how you end up guessing at --subset. Handled
# before the root check and before config.json is read, so help works on a machine
# with no backup configured and from an unprivileged shell.

usage() {
    cat <<'USAGE_EOF'
restic-ctl - inspect and control the restic backup on this machine.

USAGE
  sudo restic-ctl <command> [options]
  restic-ctl help [<command>]        detail for one command

  Everything except help needs root: the credentials under /etc/restic - the
  config, the repository password, the SSH key - are root-only by design.

READING  (fast - local files and repository metadata, no data transfer)
  status              is a backup running now, how the last one went, what the
                      timer thinks, how many recent runs failed
  snapshots           what the repository holds: the list, the age of the newest,
                      totals
  history             table of recent runs, the failed ones included
  log                 the tail of the backup log
  config              this machine's effective settings and where they live
  schedule            when the backup runs, stored intent vs installed timer

ACTING
  run                 start a backup THROUGH SYSTEMD, in the same context the
                      timer uses, and follow it
  check               verify the repository
  schedule <spec>     change when it runs and reinstall the timer
  forget <id>...      delete snapshots and prune, with a confirmation step
  restore [<id>]      restore a snapshot into a directory
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

OPTIONS
  --base DIR          where the configuration lives (default /etc/restic)
  --deep              status, snapshots: add a structural check of the repository
  --data              check: re-read actual data blobs
  --subset FRACTION   check: how much data to re-read (default 1/12, implies
                      --data); takes 1/12 or 5%
  --count N           history, log: how many entries (default 15)
  --follow            log: keep watching
  --no-wait           run: start the service and return instead of following it
  --yes               forget: skip the confirmation prompt
  --target DIR        restore: where to restore to (required)
  --retry SPEC        schedule: the second, same-day OnCalendar entry
  -h, --help          this text

  Anything not listed here is passed through to restic by exec, forget, restore,
  ls and find, so their own options work unchanged: --dry-run, --long, --include.

EXIT CODES
  0  fine    1  a problem worth acting on    2  wrong usage
USAGE_EOF
}

help_topic() {
    case "${1:-}" in
    status) cat <<'T_EOF'
restic-ctl status - is the backup healthy right now.

  sudo restic-ctl status [--deep]

Reads local state only, so it is instant and safe to run during a backup:
  State          idle, or running - and whether that comes from the systemd
                 service, from a bare restic process, or is only a stale progress
                 file (reported as "maybe")
  Progress       when a backup is running: files and bytes done so far, from
                 progress.json, which the backup script writes from restic --json.
                 This is the only way to see progress from a timer-launched run:
                 it has no terminal and therefore no progress bar.
  Last run       result, when, how long, what changed
  Timer          the unit's state, last result and next elapse
  Recent failures  counted from history.jsonl, because a failed run leaves no
                 trace in the repository at all
  Credentials    that the key and the password file are root-owned and 600

--deep also runs "restic check" (structure only, no data re-read). That contacts
the NAS and takes a minute or two on a large repository.
T_EOF
        ;;
    snapshots) cat <<'T_EOF'
restic-ctl snapshots - what the repository actually holds.

  sudo restic-ctl snapshots [--deep]

The snapshot list with its tags and paths, the age of the newest one, and the
repository totals from "restic stats". Metadata only: nothing file-sized is
downloaded.

Age is the number that matters. A repository can be perfectly healthy and
useless because the newest snapshot is three weeks old - a timer that has been
failing quietly looks exactly like this.

--deep also runs "restic check" (structure only).
T_EOF
        ;;
    run) cat <<'T_EOF'
restic-ctl run - start a backup the way the timer starts it.

  sudo restic-ctl run [--no-wait]

Starts restic-backup.service, it does not run restic itself. That matters: the
service runs with its own environment, its Nice and IOSchedulingClass, and under
ConditionACPower=true. A backup you launch by hand can succeed while the
timer-launched one fails, and then you have tested nothing.

By default it follows the run: progress from progress.json, refreshed until the
service finishes. Ctrl-C stops watching, not the backup - the unit keeps going.
--no-wait starts it and returns immediately.

If a backup is already running it refuses and points at "restic-ctl status".

Note ConditionACPower: on battery the service will not start, and systemd
records that as a skipped start, not a failure. That is deliberate.
T_EOF
        ;;
    check) cat <<'T_EOF'
restic-ctl check - verify the repository.

  sudo restic-ctl check [--data] [--subset FRACTION]

Three levels, increasing in cost:

  (default)               structure: every index, tree and pack is referenced and
                          reachable. Metadata only, no data downloaded. Minutes.
  --data --subset 1/12    re-reads a twelfth of the data blobs and verifies their
                          hashes. This is the one that catches actual corruption.
                          Costs bandwidth, not disk: nothing is written locally.
                          Twelve monthly runs cover the whole repository.
  --data --subset 100%    re-reads everything. On this repository that is hundreds
                          of gigabytes over SFTP.

--subset implies --data. It takes either a fraction (1/12) or a percentage (5%).

What check cannot tell you is whether a restore works. For that see
"restic-ctl help restore" - and note that "exec dump" verifies a file end to end
without needing any free disk space.
T_EOF
        ;;
    schedule) cat <<'T_EOF'
restic-ctl schedule - show or change when the backup runs.

  sudo restic-ctl schedule                     show
  sudo restic-ctl schedule <spec>              change the main OnCalendar entry
  sudo restic-ctl schedule [<spec>] --retry <spec>

With no argument it shows both sides and says whether they agree: the intent
stored in config.json, and what restic-backup.timer actually has installed -
both OnCalendar entries, Persistent, the next elapse and the last result.

With an argument it writes config.json first, then reinstalls the unit by calling
step 8 of the installed setup-restic-backup.sh, then re-reads both to confirm.
The unit is written in one place on purpose; two pieces of code writing the same
file is how they drift apart.

SPEC is a systemd calendar expression, and "systemd-analyze calendar <spec>" is
the way to check one before using it:

  daily                    03:00? no - 00:00. systemd's "daily" means midnight
  '*-*-* 03:30'            every day at 03:30
  '*-*-* 03,15:30'         twice a day
  Mon..Fri 20:00           weekdays only
  03:30                    accepted as a shorthand for '*-*-* 03:30'

There are two OnCalendar entries, not one. The second is the retry: if the first
run was interrupted - a suspend, the machine on battery, the NAS unreachable -
this one picks it up the same day instead of waiting until tomorrow. When the
first run succeeded, the second is a fast incremental and costs almost nothing.
--retry sets it.

Not settable here, and deliberately: ConditionACPower=true (no backup on
battery), Persistent=true (catch up after the machine was off) and
RandomizedDelaySec=15m. Unlike the Windows task there is no kill-after-N-hours
limit at all, so a long first backup cannot be cut short.

Needs the installer present in the tools directory. If it is missing, the command
prints the exact line to run instead.
T_EOF
        ;;
    history) cat <<'T_EOF'
restic-ctl history - the recent runs, including the ones that failed.

  sudo restic-ctl history [--count N]

Reads history.jsonl, appended by the backup script at the end of every run. This
file exists because the repository has no record of a failed backup: if the run
died, there is no snapshot, and "restic snapshots" shows nothing unusual.

Columns: when it started, how long it took, the result, new and changed files,
bytes added, and the snapshot id when there is one.

--count defaults to 15.
T_EOF
        ;;
    log) cat <<'T_EOF'
restic-ctl log - the backup log.

  sudo restic-ctl log [--count N] [--follow]

The tail of /var/log/restic-backup.log, written by the backup script on every
run. --follow keeps watching, for a backup in progress.

For a running backup, "status" is usually the better view: the log records what
happened at each stage, while progress.json carries the live counters. For what
systemd itself thinks, "journalctl -u restic-backup.service" is the other half.
T_EOF
        ;;
    config) cat <<'T_EOF'
restic-ctl config - this machine's effective settings.

  sudo restic-ctl config

Where the configuration lives, the NAS account and port, the tools directory, the
composed repository string, the SSH config, the backup paths, the retention
policy, then every file the system uses with its size and age, then the active
exclude patterns.

The repository string is composed from hostAlias and repoPath every time it is
needed, never stored. Two copies of the same string is one copy too many.

To change any of it, edit config.json and then re-run the installer from step 3
so the generated files follow. The exception is the schedule, which has its own
command: "restic-ctl schedule".
T_EOF
        ;;
    exec) cat <<'T_EOF'
restic-ctl exec - any restic command, against this repository.

  sudo restic-ctl exec <restic arguments>...

The repository, the password file, the cache directory and the sftp.command are
already set, so this is plain restic with the connection filled in.

  sudo restic-ctl exec snapshots --json
  sudo restic-ctl exec stats latest
  sudo restic-ctl exec diff 4f2a9c1b b9dd1b6d
  sudo restic-ctl exec dump latest /home/me/notes.txt > /dev/null

That last one is worth knowing: dump streams a file out of the repository and
verifies it end to end without writing anything to disk. It is how to prove a
restore works on a machine with no room for one.

No confirmation and no guard rails here - it is restic. Destructive commands have
their own wrappers ("forget") for exactly that reason.
T_EOF
        ;;
    forget) cat <<'T_EOF'
restic-ctl forget - delete snapshots and reclaim the space.

  sudo restic-ctl forget <snapshot-id>... [--dry-run] [--yes]

Removes the named snapshots, then prunes. Pruning is what actually frees space on
the NAS; forgetting alone only unlinks the snapshot.

  sudo restic-ctl forget b9dd1b6d --dry-run    say what would go, change nothing
  sudo restic-ctl forget b9dd1b6d              show it, then ask before doing it
  sudo restic-ctl forget b9dd1b6d --yes        no prompt

Always --dry-run first. Data shared with other snapshots is kept, so the space
freed is often far less than the snapshot's apparent size - and occasionally far
more than you expected.

Note that the scheduled backup already applies the retention policy from
config.json after every successful run. This command is for a specific snapshot
you want gone now.
T_EOF
        ;;
    restore) cat <<'T_EOF'
restic-ctl restore - restore a snapshot into a directory.

  sudo restic-ctl restore [<snapshot-id>] --target <dir>

The snapshot id defaults to "latest". --target is required, must be empty or
absent, and must not be inside a path that is itself being backed up.

A full restore needs as much free space as the snapshot holds, which is why no
machine here has had one verified yet. Three ways to verify without that space:

  sudo restic-ctl exec dump latest /home/me/notes.txt > /dev/null
      streams one file through and checks its hashes. Zero disk.
  sudo restic-ctl restore latest --target /var/tmp/restore-test --include /home/me/Documents
      a real restore of one subtree: a genuine end-to-end test at a size you can
      afford.
  sudo restic-ctl exec mount /mnt/restic
      Linux only, and the best of the three: the whole repository appears as a
      read-only filesystem, every snapshot browsable, nothing copied. Needs FUSE.
      Ctrl-C to unmount.
T_EOF
        ;;
    unlock) cat <<'T_EOF'
restic-ctl unlock - clear a stale repository lock.

  sudo restic-ctl unlock

restic locks the repository while writing. A run killed mid-flight - a suspend, a
hard power cut, an OOM kill - can leave that lock behind, and the next backup
then fails with "repository is already locked".

Only run this when no backup is actually running. Check with "restic-ctl status"
first: removing the lock out from under a live run is how a repository gets
damaged.
T_EOF
        ;;
    ls) cat <<'T_EOF'
restic-ctl ls - list what is inside a snapshot.

  sudo restic-ctl ls [<snapshot-id>] [<path>] [restic options]

Defaults to the latest snapshot. Useful for finding the exact spelling of a path
to hand to restore or dump.

  sudo restic-ctl ls latest
  sudo restic-ctl ls latest /home/me/Documents
  sudo restic-ctl ls b9dd1b6d --long
T_EOF
        ;;
    publish) cat <<'T_EOF'
restic-ctl publish - send this machine's backup state to Home Assistant.

  sudo restic-ctl publish             send it now
  sudo restic-ctl publish --dry-run   print the topics and the payloads, send nothing

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

The work is done by the installed restic-backup.sh (--publish, --publish --dry-run),
so this command reports exactly what a scheduled run would send. A machine whose
restic-backup.sh predates it says so: re-run setup-restic-backup.sh --update.

Exit codes: 0 sent (or previewed), 1 the broker did not accept it, 2 Home
Assistant is not configured.
T_EOF
        ;;
    unpublish) cat <<'T_EOF'
restic-ctl unpublish - remove this machine from Home Assistant.

  sudo restic-ctl unpublish             remove it now
  sudo restic-ctl unpublish --dry-run   print the two topics it would clear

Sends an empty retained message to both topics publish uses. Home Assistant removes
the device and its entities, and the broker forgets the last state.

The next backup announces the machine again. To retire it, stop the timer first,
then unpublish:

  sudo systemctl disable --now restic-backup.timer
  sudo restic-ctl unpublish

A machine that no longer exists can be removed from Home Assistant itself:
Settings > Devices & services > MQTT > the device > Delete.

Exit codes: 0 removed (or previewed), 1 the broker did not accept it, 2 Home
Assistant is not configured.
T_EOF
        ;;
    find) cat <<'T_EOF'
restic-ctl find - which snapshots contain a given path.

  sudo restic-ctl find <pattern> [restic options]

Searches every snapshot, so it is slower than ls. Patterns are globs; quote them
so the shell does not expand them first.

  sudo restic-ctl find 'notes.txt'
  sudo restic-ctl find '*.kdbx'
  sudo restic-ctl find '**/Documents/tax-2025*'

The answer to "did that file ever get backed up, and when did it last change".
T_EOF
        ;;
    '') usage ;;
    *)
        echo "No help topic '$1'." >&2
        echo 'Topics: status snapshots run check schedule history log config publish unpublish exec forget restore unlock ls find' >&2
        return 2 ;;
    esac
}

CMD_GIVEN=0
[ $# -gt 0 ] && case "$1" in
    status|snapshots|run|check|schedule|history|log|config) CMD="$1"; CMD_GIVEN=1; shift ;;
    exec|forget|restore|unlock|ls|find|publish|unpublish)   CMD="$1"; CMD_GIVEN=1; shift ;;
    help)      CMD='help'; CMD_GIVEN=1; shift ;;
    -h|--help) usage; exit 0 ;;
esac

# The wrapper subcommands take arbitrary restic arguments, so anything this
# script does not recognise is collected in REST and handed to restic verbatim.
while [ $# -gt 0 ]; do
    case "$1" in
        --deep)    DEEP=1; shift ;;
        --data)    DATA=1; shift ;;
        --subset)  SUBSET="$2"; DATA=1; shift 2 ;;
        --follow)  FOLLOW=1; shift ;;
        --no-wait) NOWAIT=1; shift ;;
        --yes)     YES=1; shift ;;
        --target)  TARGET="$2"; shift 2 ;;
        --count)   COUNT="$2"; shift 2 ;;
        --base)    BASE="$2"; shift 2 ;;
        --retry)   RETRY="$2"; shift 2 ;;
        -h|--help)
            # "restic-ctl forget --help" should explain forget, not print the index.
            if [ "$CMD_GIVEN" = 1 ] && [ "$CMD" != 'help' ]; then
                help_topic "$CMD"
            else
                usage
            fi
            exit 0 ;;
        *)
            case "$CMD" in
                exec|forget|restore|ls|find|help|schedule) REST="$REST $1"; shift ;;
                publish|unpublish)
                    [ "$1" = '--dry-run' ] || { echo "unknown option: $1" >&2; exit 2; }
                    PUB_DRY=1; shift ;;
                *) echo "unknown option: $1" >&2; exit 2 ;;
            esac ;;
    esac
done

# Before the root check and before config.json is read, so it works on a machine that
# has no backup configured and from an unprivileged shell.
if [ "$CMD" = 'help' ]; then
    help_topic "$(printf '%s' "$REST" | awk '{print $1}')" || exit 2
    exit 0
fi

CONFIG="$BASE/config.json"
LEGACY_ENV="$BASE/settings.env"
LOG='/var/log/restic-backup.log'
PROGRESS="$BASE/progress.json"
LAST_RUN="$BASE/last-run.json"
HISTORY="$BASE/history.jsonl"

# Checked before anything else, and after --help so that stays usable unprivileged.
# Everything this script does needs the credentials in $BASE, which are root-only by
# design: the config, the repository password, the SSH key, the log. So the honest
# failure is one line about sudo, not a confusing error from whichever read came first.
if [ "$(id -u)" != 0 ]; then
    echo "restic-ctl needs root: the backup credentials in $BASE are root-only." >&2
    echo "Try:  sudo restic-ctl ${CMD}" >&2
    exit 1
fi

if [ ! -r "$CONFIG" ]; then
    if [ -r "$LEGACY_ENV" ]; then
        echo "This machine still uses the old settings.env." >&2
        echo "Run setup-restic-backup.sh --from 3 once; it converts it to config.json." >&2
    else
        echo "No backup configured on this machine: $CONFIG not found." >&2
        echo "Run setup-restic-backup.sh first." >&2
    fi
    exit 1
fi

command -v restic >/dev/null 2>&1 || { echo 'restic is not in PATH.' >&2; exit 1; }
HAVE_PY=0; command -v python3 >/dev/null 2>&1 && HAVE_PY=1
[ "$HAVE_PY" = 1 ] || { echo 'python3 is required to read config.json.' >&2; exit 1; }

cfg() {
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[k]
print(" ".join(str(x) for x in d) if isinstance(d, list) else d)' "$CONFIG" "$1" 2>/dev/null
}

HOST_ALIAS="$(cfg nas.hostAlias)"
REPO_PATH="$(cfg nas.repoPath)"
NAS_HOST="$(cfg nas.host)"
NAS_USER="$(cfg nas.user)"
NAS_PORT="$(cfg nas.port)"
BACKUP_PATHS="$(cfg backupPaths)"
KEEP_DAILY="$(cfg retention.daily)"
KEEP_WEEKLY="$(cfg retention.weekly)"
KEEP_MONTHLY="$(cfg retention.monthly)"

# Composed, not stored, so the repository string can never drift from its parts.
RESTIC_REPOSITORY="sftp:$HOST_ALIAS:$REPO_PATH"
RESTIC_PASSWORD_FILE="$BASE/password"
RESTIC_CACHE_DIR="$BASE/cache"
SSH_CONFIG="$BASE/ssh/config"
EXCLUDE_FILE="$BASE/excludes.txt"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR
SFTP_COMMAND="ssh -F $SSH_CONFIG -o BatchMode=yes $HOST_ALIAS -s sftp"

# ---------------------------------------------------------------- output

if [ -t 1 ]; then
    C_T=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'
    C_ERR=$'\033[31m'; C_DIM=$'\033[90m'; C_W=$'\033[97m'; C_OFF=$'\033[0m'
else
    C_T=''; C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_W=''; C_OFF=''
fi

head_()  { printf '\n  %s%s%s\n  %s%s%s\n' "$C_W" "$1" "$C_OFF" \
                  "$C_DIM" "$(printf '%*s' ${#1} '' | tr ' ' '-')" "$C_OFF"; }
field()  { printf '  %s%-18s%s%s%s%s\n' "$C_DIM" "$1" "$C_OFF" "${3:-}" "$2" "$C_OFF"; }
cont()   { printf '  %-18s%s%s%s\n' '' "${2:-}" "$1" "$C_OFF"; }
info()   { printf '  %s      %s%s\n' "$C_DIM" "$1" "$C_OFF"; }
warn()   { printf '    %sWARN%s  %s\n' "$C_WARN" "$C_OFF" "$1"; }
fail()   { printf '    %sFAIL%s  %s\n' "$C_ERR" "$C_OFF" "$1"; }
ok()     { printf '    %sOK%s    %s\n' "$C_OK" "$C_OFF" "$1"; }

restic_() { restic -o "sftp.command=$SFTP_COMMAND" "$@" 2>&1; }

fmt_bytes() {
    if [ "$HAVE_PY" = 1 ]; then
        python3 -c '
import sys
try: b = float(sys.argv[1])
except (ValueError, IndexError): print("-"); raise SystemExit
for unit, div in (("TB", 1e12), ("GB", 1e9), ("MB", 1e6)):
    if b >= div:
        print("%.2f %s" % (b / div, unit)); break
else:
    print("%.0f KB" % (b / 1e3))' "${1:-0}"
    else
        echo "${1:-0} B"
    fi
}

fmt_dur() {
    s="${1:-0}"; s="${s%.*}"
    case "$s" in ''|*[!0-9]*) echo '?'; return ;; esac
    if   [ "$s" -ge 3600 ]; then printf '%dh%02dm\n' $((s/3600)) $((s%3600/60))
    elif [ "$s" -ge 60 ];   then printf '%dm%02ds\n' $((s/60)) $((s%60))
    else printf '%ds\n' "$s"; fi
}

# Reads one key out of a JSON file. Everything this script needs from JSON goes
# through here, so there is exactly one place that depends on python3.
jget() {
    [ "$HAVE_PY" = 1 ] || { echo ''; return; }
    [ -f "$1" ] || { echo ''; return; }
    python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    raise SystemExit
v = d.get(sys.argv[2])
print("" if v is None else v)' "$1" "$2" 2>/dev/null
}

outcome_color() {
    case "$1" in
        ok)                     printf '%s' "$C_OK" ;;
        warnings)               printf '%s' "$C_WARN" ;;
        failed|prune-failed)    printf '%s' "$C_ERR" ;;
        *)                      printf '%s' "$C_OFF" ;;
    esac
}

# A backup counts as running only if restic is alive AND the progress file is fresh.
# Either alone lies: a crashed run leaves a stale file, and a run that just started
# has no file yet.
restic_running() { pgrep -x restic >/dev/null 2>&1; }
progress_fresh() {
    [ -f "$PROGRESS" ] || return 1
    [ "$(( $(date +%s) - $(stat -c %Y "$PROGRESS") ))" -lt 300 ]
}

# =============================================================== status

cmd_status() {
    printf '\n  %srestic backup - %s%s      %s%s%s\n' \
        "$C_T" "$(hostname -s)" "$C_OFF" "$C_DIM" "$(date '+%Y-%m-%d %H:%M')" "$C_OFF"

    head_ 'Current run'
    if restic_running && progress_fresh; then
        pct="$(jget "$PROGRESS" percentDone)"
        filled=$(( ${pct%.*} / 5 ))
        bar="[$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' $((20-filled)) '' | tr ' ' '.')]"
        field 'State' "RUNNING" "$C_WARN"
        field 'Progress' "$bar ${pct}%" "$C_W"
        cont "$(jget "$PROGRESS" filesDone) of $(jget "$PROGRESS" totalFiles) files, \
$(fmt_bytes "$(jget "$PROGRESS" bytesDone)") of $(fmt_bytes "$(jget "$PROGRESS" totalBytes)")"
        rem="$(jget "$PROGRESS" secondsRemaining)"
        [ -n "$rem" ] && cont "ETA ~$(fmt_dur "$rem")"
        cur="$(jget "$PROGRESS" currentFile)"
        [ -n "$cur" ] && cont "at $cur" "$C_DIM"
    elif restic_running; then
        field 'State' 'restic is running, but there is no fresh progress data' "$C_WARN"
        cont 'It may be scanning, or in forget/prune.'
    else
        field 'State' 'idle'
        [ -f "$PROGRESS" ] && cont 'A stale progress.json is left from an interrupted run.' "$C_WARN"
    fi

    head_ 'Last completed run'
    if [ ! -f "$LAST_RUN" ]; then
        field 'State' 'no run recorded yet' "$C_WARN"
    else
        oc="$(jget "$LAST_RUN" outcome)"
        field 'Outcome' "$(echo "$oc" | tr '[:lower:]' '[:upper:]')   (took $(fmt_dur "$(jget "$LAST_RUN" durationSec)"))" \
              "$(outcome_color "$oc")"
        cont "finished $(jget "$LAST_RUN" finishedAt), exit code $(jget "$LAST_RUN" exitCode)"
        sid="$(jget "$LAST_RUN" snapshotId)"
        if [ -n "$sid" ]; then
            cont "snapshot ${sid:0:8}  -  $(jget "$LAST_RUN" filesNew) new / \
$(jget "$LAST_RUN" filesChanged) changed files, $(fmt_bytes "$(jget "$LAST_RUN" dataAddedBytes)") added"
        fi
    fi

    if [ -f "$HISTORY" ] && [ "$HAVE_PY" = 1 ]; then
        summary="$(python3 -c '
import json, sys
runs = []
for line in open(sys.argv[1]):
    line = line.strip()
    if line:
        try: runs.append(json.loads(line))
        except ValueError: pass
runs = runs[-30:]
bad = [r for r in runs if r.get("outcome") not in ("ok", "warnings")]
warn = [r for r in runs if r.get("outcome") == "warnings"]
print("%d|%d|%d|%s" % (len(runs), len(bad), len(warn),
      (bad[-1].get("finishedAt", "?") + " exit " + str(bad[-1].get("exitCode"))) if bad else ""))
' "$HISTORY" 2>/dev/null)"
        if [ -n "$summary" ]; then
            total="${summary%%|*}"; rest="${summary#*|}"
            nbad="${rest%%|*}";     rest="${rest#*|}"
            nwarn="${rest%%|*}";    lastbad="${rest#*|}"
            col="$C_OK"
            [ "$nwarn" -gt 0 ] && col="$C_WARN"
            [ "$nbad" -gt 0 ] && col="$C_ERR"
            field 'Recent runs' "$total recorded, $nbad failed, $nwarn with warnings" "$col"
            [ -n "$lastbad" ] && cont "last failure $lastbad" "$C_ERR"
        fi
    fi

    head_ 'Scheduler'
    if ! systemctl list-unit-files "$TIMER" >/dev/null 2>&1 || \
       ! systemctl cat "$TIMER" >/dev/null 2>&1; then
        field 'Timer' "$TIMER is not installed" "$C_ERR"
        cont 'Nothing will run automatically. setup-restic-backup.sh --from 8' "$C_WARN"
    else
        tstate="$(systemctl is-enabled "$TIMER" 2>/dev/null)"
        tactive="$(systemctl is-active "$TIMER" 2>/dev/null)"
        tcol="$C_OK"; [ "$tstate" = 'enabled' ] || tcol="$C_ERR"
        field 'Timer' "$TIMER   $tstate / $tactive" "$tcol"
        systemctl list-timers --all "$TIMER" --no-pager --no-legend 2>/dev/null | \
            while read -r line; do cont "$line" "$C_DIM"; done
        sstate="$(systemctl is-active "$SERVICE" 2>/dev/null)"
        sres="$(systemctl show -p Result --value "$SERVICE" 2>/dev/null)"
        scol="$C_OFF"; [ "$sres" = 'success' ] || scol="$C_ERR"
        field 'Last service run' "state $sstate, result $sres" "$scol"
        ts="$(systemctl show -p ExecMainExitTimestamp --value "$SERVICE" 2>/dev/null)"
        [ -n "$ts" ] && cont "finished $ts"
    fi

    head_ 'Credentials'
    key="$BASE/ssh/id_ed25519"
    if [ ! -f "$key" ]; then
        field 'SSH key' 'missing' "$C_ERR"
    else
        # ssh refuses a private key that is group- or world-readable, and the timer
        # runs as root, so owner must be root. The Windows counterpart of this check
        # catches a subtler variant, where the owner is a user account.
        mode="$(stat -c %a "$key")"
        owner="$(stat -c %U "$key")"
        if [ "$mode" = '600' ] && [ "$owner" = 'root' ]; then
            field 'SSH key' "$owner $mode" "$C_OK"
        else
            field 'SSH key' "$owner $mode" "$C_ERR"
            cont 'ssh will refuse this key. Expected root and mode 600.' "$C_ERR"
            cont "Fix:  chown root:root $key && chmod 600 $key" "$C_WARN"
        fi
    fi

    head_ 'Repository'
    field 'Target' "$RESTIC_REPOSITORY"
    snap="$(restic_ snapshots --json --latest 1)"
    if [ $? -ne 0 ]; then
        field 'Reachable' 'NO' "$C_ERR"
        cont "$(printf '%s' "$snap" | head -n 2 | tr '\n' ' ')" "$C_DIM"
    elif [ "$HAVE_PY" = 1 ]; then
        info="$(printf '%s' "$snap" | python3 -c '
import json, sys, datetime
try: s = json.load(sys.stdin)
except Exception: s = []
if not s:
    print("EMPTY"); raise SystemExit
n = s[0]
t = datetime.datetime.fromisoformat(n["time"].split(".")[0].replace("Z", ""))
age = (datetime.datetime.now() - t).total_seconds()
print("%s|%d|%s|%s" % (t.strftime("%Y-%m-%d %H:%M"), age, n.get("short_id",""), n.get("hostname","")))
' 2>/dev/null)"
        if [ "$info" = 'EMPTY' ] || [ -z "$info" ]; then
            field 'Reachable' 'yes, but the repository has no snapshots' "$C_WARN"
        else
            when="${info%%|*}"; rest="${info#*|}"
            age="${rest%%|*}";  rest="${rest#*|}"
            sid="${rest%%|*}";  shost="${rest#*|}"
            # Two days without a snapshot on a daily schedule means something is wrong,
            # even if the last recorded run says it succeeded.
            acol="$C_OK"
            [ "$age" -gt 104000 ] && acol="$C_WARN"
            [ "$age" -gt 172800 ] && acol="$C_ERR"
            field 'Newest snapshot' "$when   ($(fmt_dur "$age") ago)" "$acol"
            cont "id $sid, host $shost"
        fi
    else
        field 'Reachable' 'yes' "$C_OK"
    fi

    if [ "$DEEP" = 1 ]; then
        head_ 'Integrity'
        do_check 0
    else
        printf '\n  %s--deep adds a structural check of the repository.%s\n' "$C_DIM" "$C_OFF"
    fi
    printf '\n'
}

# ============================================================ snapshots

cmd_snapshots() {
    printf '\n'
    field 'Repository' "$RESTIC_REPOSITORY"
    out="$(restic_ snapshots)"
    if [ $? -ne 0 ]; then
        printf '\n  %sCannot reach the repository.%s\n' "$C_ERR" "$C_OFF"
        printf '%s\n' "$out" | sed 's/^/    /'
        exit 1
    fi
    head_ 'Snapshots'
    printf '%s\n' "$out" | sed 's/^/  /'

    head_ 'Coverage'
    field 'Retention' "$KEEP_DAILY daily, $KEEP_WEEKLY weekly, $KEEP_MONTHLY monthly"

    head_ 'Size'
    for mode in restore-size raw-data; do
        st="$(restic_ stats --mode "$mode" | tail -n 3 | tr '\n' ' ' | tr -s ' ')"
        field "$mode" "$st"
    done

    if [ "$DEEP" = 1 ]; then
        head_ 'Integrity'
        do_check 0
    fi
    printf '\n'
}

# ================================================================ check

# What this proves, and what it does not: "check" verifies the repository - the index
# agrees with the pack files, nothing referenced is missing. "check --data" additionally
# re-reads a fraction of the packs and verifies their hashes, which is what catches bit
# rot. Neither proves you can get your files back: for that see the dump and mount
# techniques the RUNBOOK describes, both of which need no local disk space.
do_check() {
    if [ "${1:-0}" = 1 ]; then
        field 'Running' "restic check --read-data-subset $SUBSET" "$C_DIM"
        cont "Re-reads that fraction of the pack files. Nothing is written to disk -" "$C_DIM"
        cont "the data is streamed and discarded - but it is downloaded." "$C_DIM"
        out="$(restic_ check --read-data-subset "$SUBSET")"
    else
        field 'Running' 'restic check' "$C_DIM"
        cont 'Structure only: no data is downloaded, no disk space is used.' "$C_DIM"
        out="$(restic_ check)"
    fi
    if [ $? -eq 0 ]; then
        field 'Result' 'no errors were found' "$C_OK"
    else
        field 'Result' 'FAILED' "$C_ERR"
        printf '%s\n' "$out" | sed 's/^/    /'
    fi
}

cmd_check() {
    printf '\n'
    field 'Repository' "$RESTIC_REPOSITORY"
    head_ 'Integrity'
    do_check "$DATA"
    if [ "$DATA" = 0 ]; then
        printf '\n  %s--data re-reads a fraction of the blobs too (catches bit rot).%s\n' "$C_DIM" "$C_OFF"
        printf '  %s--subset 1/12 or --subset 5%% sets that fraction; twelve monthly 1/12 runs%s\n' "$C_DIM" "$C_OFF"
        printf '  %scover everything.%s\n' "$C_DIM" "$C_OFF"
    fi
    printf '\n  %sNeither check proves a restore works. With no disk space to spare:%s\n' "$C_W" "$C_OFF"
    printf '    restic-ctl exec dump latest /etc/fstab | diff - /etc/fstab\n'
    printf '    restic-ctl exec dump --archive tar latest / > /dev/null\n'
    printf '    sudo restic mount /mnt/restic     # then compare whatever you like\n'
    printf '\n'
}

# ============================================================== history

cmd_history() {
    if [ ! -f "$HISTORY" ]; then
        printf '\n  %sNo run history yet (%s).%s\n' "$C_WARN" "$HISTORY" "$C_OFF"
        printf '  %sIt is written from the first completed backup onwards.%s\n\n' "$C_DIM" "$C_OFF"
        return
    fi
    [ "$HAVE_PY" = 1 ] || { echo 'python3 is needed to format the history.'; tail -n "$COUNT" "$HISTORY"; return; }

    COUNT="$COUNT" python3 -c '
import json, os, sys
runs = []
for line in open(sys.argv[1]):
    line = line.strip()
    if line:
        try: runs.append(json.loads(line))
        except ValueError: pass
n = int(os.environ.get("COUNT", 15))
def human(b):
    if b is None: return "-"
    for u, d in (("TB",1e12), ("GB",1e9), ("MB",1e6)):
        if b >= d: return "%.2f %s" % (b/d, u)
    return "%.0f KB" % (b/1e3)
def dur(s):
    if s is None: return "-"
    s = int(s)
    if s >= 3600: return "%dh%02dm" % (s//3600, s%3600//60)
    if s >= 60: return "%dm%02ds" % (s//60, s%60)
    return "%ds" % s
COL = {"ok": "\033[32m", "warnings": "\033[33m", "failed": "\033[31m", "prune-failed": "\033[31m"}
OFF = "\033[0m"
tty = sys.stdout.isatty()
print()
print("  Run history - last %d of %d" % (min(n, len(runs)), len(runs)))
print()
print("  %-17s %-13s %-9s %-9s %-8s %s" % ("Finished", "Outcome", "Duration", "Added", "Snapshot", "Files new/chg"))
for r in runs[-n:]:
    oc = r.get("outcome", "?")
    col = COL.get(oc, "") if tty else ""
    off = OFF if tty and col else ""
    fin = (r.get("finishedAt") or "?")[:16].replace("T", " ")
    sid = (r.get("snapshotId") or "-")[:8]
    fls = "-" if r.get("filesNew") is None else "%s / %s" % (r.get("filesNew"), r.get("filesChanged"))
    print("  %-17s %s%-13s%s %-9s %-9s %-8s %s" % (
        fin, col, oc, off, dur(r.get("durationSec")), human(r.get("dataAddedBytes")), sid, fls))
bad = [r for r in runs if r.get("outcome") not in ("ok", "warnings")]
print()
print("  Totals            %d runs, %d failed (%.0f%%)" % (
    len(runs), len(bad), 100.0 * len(bad) / len(runs) if runs else 0))
print()
' "$HISTORY"
}

# ================================================================== run

# "Is a backup running" is not the same question as "is restic running". pgrep restic
# matches ANY restic: a manual "restic snapshots" in another terminal, this script's own
# exec subcommand, the installer. Using that alone made run refuse to start when nothing
# was backing up at all.
#   service  systemd says its own run is going - authoritative
#   restic   restic is running and writing backup progress
#   maybe    restic is running but writing no progress: probably another restic command
backup_in_progress() {
    st="$(systemctl is-active "$SERVICE" 2>/dev/null)"
    case "$st" in active|activating) echo service; return ;; esac
    if restic_running && progress_fresh; then echo restic; return; fi
    if restic_running; then echo maybe; return; fi
    echo ''
}

cmd_run() {
    case "$(backup_in_progress)" in
        service)
            printf '\n  %sThe timer'"'"'s service is already running. Showing its progress.%s\n' "$C_WARN" "$C_OFF"
            watch_run; return ;;
        restic)
            printf '\n  %sA backup is already running. Showing its progress instead.%s\n' "$C_WARN" "$C_OFF"
            watch_run; return ;;
        maybe)
            printf '\n'
            warn 'A restic process is running, but it is not writing backup progress.'
            info 'Most likely another restic command - snapshots, check, a manual run -'
            info 'rather than a backup. Starting one now would contend for the repository'
            info 'lock and one of the two would fail.'
            printf '\n  %sSee what it is:%s\n' "$C_W" "$C_OFF"
            printf '    ps -o pid,lstart,cmd -C restic\n\n'
            if [ "$YES" = 0 ]; then
                info 'Re-run with --yes to start the backup anyway.'
                printf '\n'
                return
            fi
            info 'Starting anyway (--yes).' ;;
    esac
    if ! systemctl cat "$SERVICE" >/dev/null 2>&1; then
        printf '\n  %s%s is not installed.%s\n' "$C_ERR" "$SERVICE" "$C_OFF"
        printf '  %sInstall it with: setup-restic-backup.sh --from 8%s\n\n' "$C_WARN" "$C_OFF"
        exit 1
    fi

    # Deliberately through systemd, not by calling the backup script: this is the only
    # way to exercise the real run context - root, its environment, the network as the
    # service sees it - instead of just the script logic.
    printf '\n'
    field 'Starting' "systemctl start $SERVICE" "$C_T"
    systemctl start --no-block "$SERVICE"
    sleep 3

    if [ "$NOWAIT" = 1 ]; then
        field 'Started' 'not waiting (--no-wait). Check with: restic-ctl status'
        printf '\n'
        return
    fi
    watch_run
}

watch_run() {
    printf '  %sCtrl+C stops watching; the backup keeps going.%s\n\n' "$C_DIM" "$C_OFF"
    spin=0
    chars='|/-\'
    while :; do
        if ! restic_running && [ "$(systemctl is-active "$SERVICE" 2>/dev/null)" != 'activating' ] \
           && [ "$(systemctl is-active "$SERVICE" 2>/dev/null)" != 'active' ]; then
            sleep 3
            printf '\r%*s\r' 100 ''
            if [ -f "$LAST_RUN" ]; then
                oc="$(jget "$LAST_RUN" outcome)"
                field 'Finished' "$(echo "$oc" | tr '[:lower:]' '[:upper:]')" "$(outcome_color "$oc")"
                cont "took $(fmt_dur "$(jget "$LAST_RUN" durationSec)"), exit code $(jget "$LAST_RUN" exitCode)"
                sid="$(jget "$LAST_RUN" snapshotId)"
                [ -n "$sid" ] && cont "snapshot ${sid:0:8}, $(fmt_bytes "$(jget "$LAST_RUN" dataAddedBytes)") added"
            else
                field 'Finished' 'no record was written' "$C_WARN"
                cont 'Check the log: restic-ctl log' "$C_DIM"
            fi
            printf '\n'
            return
        fi
        tick="$(printf '%s' "$chars" | cut -c $(( spin % 4 + 1 )))"
        spin=$((spin + 1))
        if progress_fresh; then
            pct="$(jget "$PROGRESS" percentDone)"
            filled=$(( ${pct%.*} / 5 ))
            bar="[$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' $((20-filled)) '' | tr ' ' '.')]"
            line="  $tick $bar ${pct}%  $(fmt_bytes "$(jget "$PROGRESS" bytesDone)") / \
$(fmt_bytes "$(jget "$PROGRESS" totalBytes)")  ETA $(fmt_dur "$(jget "$PROGRESS" secondsRemaining)")"
        else
            line="  $tick running - no progress data yet (scanning, or in forget/prune)"
        fi
        printf '\r%-100s' "$line"
        sleep 5
    done
}

# ================================================================== log

cmd_log() {
    if [ ! -f "$LOG" ]; then
        printf '\n  %sNo log yet (%s).%s\n\n' "$C_WARN" "$LOG" "$C_OFF"
        return
    fi
    head_ "Log - last $COUNT lines of $LOG"
    printf '\n'
    if [ "$FOLLOW" = 1 ]; then
        tail -n "$COUNT" -f "$LOG"
    else
        tail -n "$COUNT" "$LOG"
        printf '\n  %s--follow keeps watching. journalctl -u %s for the service side.%s\n\n' \
            "$C_DIM" "$SERVICE" "$C_OFF"
    fi
}

# =============================================================== config

cmd_config() {
    head_ 'Effective configuration'
    field 'Config file'   "$CONFIG"
    field 'NAS'           "$NAS_USER@$NAS_HOST:$NAS_PORT"
    field 'Repository'    "$RESTIC_REPOSITORY"
    field 'SSH config'    "$SSH_CONFIG"
    field 'Host alias'    "$HOST_ALIAS"
    field 'Backup paths'  "$BACKUP_PATHS"
    field 'Retention'     "$KEEP_DAILY daily, $KEEP_WEEKLY weekly, $KEEP_MONTHLY monthly"
    ha_host="$(cfg homeAssistant.host)"
    if [ -n "$ha_host" ]; then
        ha_box="$(cfg homeAssistant.box)";     ha_box="${ha_box:-$NAS_USER}"
        ha_topic="$(cfg homeAssistant.topic)"; ha_topic="${ha_topic:-restic/$ha_box}"
        ha_user="$(cfg homeAssistant.user)";   ha_port="$(cfg homeAssistant.port)"
        field 'Home Assistant' "${ha_user:-<no user>}@$ha_host:${ha_port:-1883}"
        field 'HA box/topic'   "$ha_box  ->  $ha_topic"
    else
        field 'Home Assistant' 'not configured' "$C_DIM"
    fi

    head_ 'Files'
    for pair in "Log:$LOG" "Excludes:$EXCLUDE_FILE" "Password:$RESTIC_PASSWORD_FILE" \
                "MQTT password:$BASE/mqtt-password" \
                "Last run:$LAST_RUN" "History:$HISTORY" "Progress:$PROGRESS"; do
        label="${pair%%:*}"; path="${pair#*:}"
        if [ -f "$path" ]; then
            field "$label" "$path   ($(stat -c %s "$path") bytes, $(date -d "@$(stat -c %Y "$path")" '+%Y-%m-%d %H:%M'))"
        else
            field "$label" "$path   (absent)" "$C_DIM"
        fi
    done

    head_ 'Exclude patterns'
    if [ -f "$EXCLUDE_FILE" ]; then
        n="$(grep -cve '^\s*$' -e '^\s*#' "$EXCLUDE_FILE" || true)"
        field 'Active' "$n patterns"
        grep -ve '^\s*$' -e '^\s*#' "$EXCLUDE_FILE" | sed "s/^/                     /"
    fi
    printf '\n'
}

# ============================================================= schedule

# --on-calendar and --retry-calendar used to be options of setup-restic-backup.sh.
# They were in the wrong place: changing when the backup runs meant re-running the
# installer, and "--only 8 --on-calendar ..." rewrote the unit while config.json still
# held the old value - drift of exactly the kind that made the NAS account revert on one
# machine. So the knobs live here and the unit is still written by step 8 of the
# installer: one writer for the file, one command to change it.

schedule_intent()  { cfg schedule.onCalendar; }
schedule_retry()   { cfg schedule.retryCalendar; }

schedule_report() {
    want="$(schedule_intent)"; want_retry="$(schedule_retry)"

    head_ 'Stored intent (config.json)'
    field 'OnCalendar' "${want:-(not recorded)}"
    field 'Retry'      "${want_retry:-(not recorded)}"

    head_ 'Installed timer'
    if ! systemctl cat "$TIMER" >/dev/null 2>&1; then
        fail "$TIMER is not installed"
        info 'Run setup-restic-backup.sh --only 8 to install it.'
        return
    fi
    have="$(grep '^OnCalendar=' /etc/systemd/system/restic-backup.timer 2>/dev/null |
            sed 's/^OnCalendar=//')"
    # Printed line by line rather than joined: a spec contains spaces, and squashing
    # them together is how you end up unable to tell two entries apart.
    if [ -n "$have" ]; then
        i=1
        printf '%s\n' "$have" | while IFS= read -r line; do
            [ -n "$line" ] || continue
            field "OnCalendar $i" "$line"
            i=$((i + 1))
        done
    else
        field 'OnCalendar' '(none - the timer never fires)' "$C_ERR"
    fi
    field 'Persistent' "$(systemctl show -p Persistent --value "$TIMER" 2>/dev/null)"
    field 'Enabled'    "$(systemctl is-enabled "$TIMER" 2>/dev/null) / $(systemctl is-active "$TIMER" 2>/dev/null)"
    systemctl list-timers --all "$TIMER" --no-pager --no-legend 2>/dev/null |
        sed 's/^/                    /' | head -3

    printf '\n'
    # The whole reason this report shows both sides.
    diff_found=0
    first_have="$(printf '%s\n' "$have" | sed -n '1p')"
    scnd_have="$(printf '%s\n' "$have" | sed -n '2p')"
    if [ -n "$want" ] && [ "$want" != "$first_have" ]; then
        warn "OnCalendar: config.json says '$want', the timer says '$first_have'"
        diff_found=1
    fi
    if [ -n "$want_retry" ] && [ "$want_retry" != "$scnd_have" ]; then
        warn "retry: config.json says '$want_retry', the timer says '$scnd_have'"
        diff_found=1
    fi
    if [ "$diff_found" = 0 ]; then
        ok 'the stored intent and the installed timer agree'
    else
        info 'Re-run "restic-ctl schedule <spec>" to make the timer follow config.json.'
    fi
}

cmd_schedule() {
    new="${REST# }"
    if [ -z "$new" ] && [ -z "$RETRY" ]; then
        schedule_report
        printf '\n'
        info 'To change it:  restic-ctl schedule 03:30'
        info "               restic-ctl schedule '*-*-* 03,15:30'"
        info "               restic-ctl schedule --retry '*-*-* 19:17'"
        printf '\n'
        return
    fi

    want="$(schedule_intent)"; want_retry="$(schedule_retry)"
    spec="${new:-$want}"
    [ -n "$spec" ] || spec='daily'
    retry="${RETRY:-$want_retry}"
    [ -n "$retry" ] || retry='*-*-* 19:17'

    # A bare HH:MM is the thing anyone types first, and systemd accepts it - but as
    # a one-off today, not as a daily entry. Expanded rather than silently misread.
    case "$spec" in
        [0-9][0-9]:[0-9][0-9]|[0-9]:[0-9][0-9]) spec="*-*-* $spec" ;;
    esac
    case "$retry" in
        [0-9][0-9]:[0-9][0-9]|[0-9]:[0-9][0-9]) retry="*-*-* $retry" ;;
    esac

    # Validated before anything is written. systemd-analyze is the authority on what
    # is a legal calendar expression, and a bad one in the unit file means a timer
    # that silently never fires.
    for s in "$spec" "$retry"; do
        if command -v systemd-analyze >/dev/null 2>&1; then
            if ! systemd-analyze calendar "$s" >/dev/null 2>&1; then
                printf '\n'
                fail "systemd does not accept '$s' as a calendar expression"
                info "Try:  systemd-analyze calendar '*-*-* 03:30'"
                printf '\n'
                exit 2
            fi
        fi
    done

    # The installer owns the unit. Finding it here rather than duplicating the
    # heredoc means the two can never disagree.
    # Two places, because a machine set up before this was fixed has "/usr/local/bin"
    # stored in paths.tools - the PATH directory, not the tools directory - and an
    # --update is what corrects it. Looking in the built-in default as well means the
    # command works on such a machine instead of only explaining itself.
    installer=''
    for _t in "$(cfg paths.tools)" '/usr/local/lib/restic-backup'; do
        [ -n "$_t" ] || continue
        if [ -f "$_t/setup-restic-backup.sh" ]; then
            installer="$_t/setup-restic-backup.sh"
            break
        fi
    done
    if [ -z "$installer" ]; then
        tools="$(cfg paths.tools)"
        [ -n "$tools" ] || tools='/usr/local/lib/restic-backup'
        installer="$tools/setup-restic-backup.sh"
    fi
    if [ ! -f "$installer" ]; then
        printf '\n'
        fail "the installer is not where config.json says it is: $installer"
        info 'Nothing has been changed. Either re-run the installer with --update so it'
        info 'installs itself there, or apply the change by hand from your own copy:'
        info '  sudo ./setup-restic-backup.sh --only 8'
        printf '\n'
        exit 1
    fi

    head_ 'Changing the schedule'
    if [ -n "$want" ] && [ "$want" != "$spec" ]; then
        field 'OnCalendar' "$want  ->  $spec"
    else
        field 'OnCalendar' "$spec"
    fi
    if [ -n "$want_retry" ] && [ "$want_retry" != "$retry" ]; then
        field 'Retry' "$want_retry  ->  $retry"
    else
        field 'Retry' "$retry"
    fi

    SPEC="$spec" RETRY_SPEC="$retry" python3 -c '
import json, os, sys
p = sys.argv[1]
with open(p) as f:
    d = json.load(f)
s = d.setdefault("schedule", {})
s["onCalendar"] = os.environ["SPEC"]
s["retryCalendar"] = os.environ["RETRY_SPEC"]
import datetime
d["updated"] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
tmp = p + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
os.replace(tmp, p)
' "$CONFIG" || { fail 'could not update config.json'; exit 1; }
    chmod 600 "$CONFIG"
    ok 'config.json updated'

    head_ 'Reinstalling the timer'
    info "$installer --only 8"
    printf '\n'
    bash "$installer" --only 8 --base "$BASE"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '\n'
        fail "the installer exited $rc; config.json was updated but the timer may not have been"
        info 'Fix whatever it reported, then run this command again.'
        printf '\n'
        exit 1
    fi

    # Re-read both sides from disk. A step that reported success without its effect
    # being checked is the single most common bug in this whole system.
    printf '\n'
    schedule_report
    printf '\n'
}

# ======================================================= restic passthrough

# The point of these: never retype the repository, the password file and the
# sftp.command again. They are the same restic you would run by hand, with this
# machine's connection already set up.

cmd_exec() {
    if [ -z "${REST# }" ]; then
        printf '\n  %sUsage: restic-ctl exec <restic arguments...>%s\n' "$C_WARN" "$C_OFF"
        printf '  %se.g.   restic-ctl exec snapshots --json%s\n' "$C_DIM" "$C_OFF"
        printf '  %s       restic-ctl exec stats latest%s\n' "$C_DIM" "$C_OFF"
        printf '  %s       restic-ctl exec diff 4f2a9c1b b9dd1b6d%s\n\n' "$C_DIM" "$C_OFF"
        return
    fi
    printf '\n'
    field 'Running' "restic$REST" "$C_DIM"
    printf '\n'
    # shellcheck disable=SC2086
    restic_ $REST | sed 's/^/  /'
    rc=$?
    printf '\n'
    [ "$rc" -eq 0 ] || exit "$rc"
}

cmd_forget() {
    ids=''; flags=''; dry=0
    for a in $REST; do
        case "$a" in
            --dry-run) dry=1; flags="$flags $a" ;;
            -*)        flags="$flags $a" ;;
            *)         ids="$ids $a" ;;
        esac
    done

    if [ -z "${ids# }" ]; then
        printf '\n  %sUsage: restic-ctl forget <snapshot-id> [<id>...] [--dry-run]%s\n\n' "$C_WARN" "$C_OFF"
        info 'Removes those snapshots and prunes the data they alone referenced.'
        info 'Without --dry-run you are asked to confirm; --yes skips the question.'
        printf '\n  %sCurrent snapshots:%s\n' "$C_W" "$C_OFF"
        restic_ snapshots | sed 's/^/  /'
        printf '\n'
        return
    fi

    n="$(printf '%s' "$ids" | wc -w | tr -d ' ')"
    printf '\n'
    field 'Snapshots' "${ids# }" "$C_W"

    if [ "$dry" = 0 ] && [ "$YES" = 0 ]; then
        # Destructive and not undoable: the data of a forgotten snapshot is gone
        # once prune has run.
        printf '\n'
        printf '    %sWARN%s  This deletes those snapshots and prunes their data. It cannot be undone.\n' \
            "$C_WARN" "$C_OFF"
        info 'Run the same command with --dry-run first if you have not.'
        printf '    Type the number of snapshots to remove (%s) to confirm: ' "$n"
        read -r answer
        if [ "$answer" != "$n" ]; then
            printf '\n'
            fail 'not confirmed, nothing was changed'
            printf '\n'
            return
        fi
    fi

    if [ "$dry" = 1 ]; then
        set -- forget $ids $flags          # --prune is meaningless in a dry run
    else
        set -- forget $ids --prune $flags
    fi
    field 'Running' "restic $*" "$C_DIM"
    printf '\n'
    restic_ "$@" | sed 's/^/  /'
    rc=$?
    printf '\n'
    if [ "$rc" -eq 0 ]; then
        if [ "$dry" = 1 ]; then field 'Result' 'dry run, nothing was changed' "$C_OK"
        else field 'Result' 'done' "$C_OK"; fi
    else
        field 'Result' "FAILED (exit $rc)" "$C_ERR"
    fi
    printf '\n'
}

cmd_restore() {
    id='latest'
    for a in $REST; do
        case "$a" in -*) ;; *) id="$a"; break ;; esac
    done

    if [ -z "$TARGET" ]; then
        printf '\n  %sUsage: restic-ctl restore [<snapshot-id>] --target <folder>%s\n' "$C_WARN" "$C_OFF"
        printf '  %se.g.   restic-ctl restore latest --target /var/tmp/restore-test%s\n\n' "$C_DIM" "$C_OFF"
        info 'Restores into a NEW folder; it never writes over the original paths.'
        info 'Do this at least once per machine: an untested backup is a guess.'
        printf '\n'
        return
    fi
    if [ -d "$TARGET" ] && [ -n "$(ls -A "$TARGET" 2>/dev/null)" ]; then
        printf '\n'
        fail "$TARGET already exists and is not empty"
        info 'Pick an empty or new folder, so a restore cannot mix with real data.'
        printf '\n'
        return
    fi

    printf '\n'
    field 'Snapshot' "$id" "$C_W"
    field 'Target'   "$TARGET"
    field 'Running'  "restic restore $id --target $TARGET" "$C_DIM"
    printf '\n'
    restic_ restore "$id" --target "$TARGET" | sed 's/^/  /'
    rc=$?
    printf '\n'
    if [ "$rc" -eq 0 ]; then
        field 'Result' 'restored' "$C_OK"
        info 'Now compare a few files against the originals before trusting it.'
    else
        field 'Result' "FAILED (exit $rc)" "$C_ERR"
    fi
    printf '\n'
}

cmd_unlock() {
    printf '\n'
    field 'Running' 'restic unlock' "$C_DIM"
    restic_ unlock | sed 's/^/  /'
    info 'Only locks with no live process are removed; a running backup keeps its own.'
    printf '\n'
}

cmd_ls() {
    id='latest'
    for a in $REST; do
        case "$a" in -*) ;; *) id="$a"; break ;; esac
    done
    printf '\n'
    field 'Snapshot' "$id" "$C_W"
    printf '\n'
    restic_ ls "$id" | sed 's/^/  /'
    printf '\n'
}

cmd_find() {
    if [ -z "${REST# }" ]; then
        printf '\n  %sUsage: restic-ctl find <pattern>%s\n' "$C_WARN" "$C_OFF"
        printf '  %se.g.   restic-ctl find "*.kdbx"%s\n\n' "$C_DIM" "$C_OFF"
        return
    fi
    printf '\n'
    field 'Pattern' "${REST# }" "$C_W"
    printf '\n'
    # shellcheck disable=SC2086
    restic_ find $REST | sed 's/^/  /'
    printf '\n'
}

# ============================================================== publish

# Delegates to the installed backup script rather than carrying a second copy of the
# MQTT code: what this sends, or previews, is by construction what the scheduled run
# sends. Serves both publish and unpublish.
cmd_publish() {
    script='/usr/local/bin/restic-backup.sh'
    [ -x "$script" ] || { fail "$script not found - run setup-restic-backup.sh"; exit 1; }
    if [ "$CMD" = 'unpublish' ]; then
        flag='--unpublish'; want='--unpublish'
    else
        # Discovery came after --publish: a script that has --publish but no
        # discovery would report success while Home Assistant shows no device.
        flag='--publish'; want='DISCOVERY_PREFIX'
    fi
    if ! grep -q -- "$want" "$script"; then
        fail 'the installed restic-backup.sh predates this command'
        info 'Bring it up to date:  sudo ./setup-restic-backup.sh --update'
        info "(run the copy you brought, or $(cfg paths.tools)/setup-restic-backup.sh)"
        printf '\n'; exit 1
    fi

    if [ "$PUB_DRY" = 1 ]; then
        if [ "$CMD" = 'unpublish' ]; then
            head_ 'Home Assistant removal (dry run, nothing sent)'
        else
            head_ 'Home Assistant messages (dry run, nothing sent)'
        fi
        out="$("$script" "$flag" --dry-run 2>&1)"; rc=$?
        # The first lines are "Label  value" (two or more spaces between them, the
        # label may itself contain one); the JSON after them is shown as-is.
        printf '%s\n' "$out" | while IFS= read -r line; do
            case "$line" in
                [A-Z]*'  '*)
                    label="${line%%  *}"
                    value="$(printf '%s' "${line#"$label"}" | sed 's/^ *//')"
                    field "$label" "$value" ;;
                *)  printf '    %s\n' "$line" ;;
            esac
        done
        printf '\n'
        exit "$rc"
    fi

    head_ 'Home Assistant'
    out="$("$script" "$flag" 2>&1)"; rc=$?
    case "$rc" in
        0) ok "$out"
           [ "$CMD" = 'unpublish' ] && \
               info 'The next backup announces it again. To retire the machine, first: sudo systemctl disable --now restic-backup.timer' ;;
        2) field 'State' 'not configured' "$C_DIM"
           info 'Enable it with: sudo ./setup-restic-backup.sh --only 3 --ha-host <broker> --ha-user <user>' ;;
        *) fail "$out"
           info 'Details in the log:  sudo restic-ctl log | grep "ha:"' ;;
    esac
    printf '\n'
    exit "$rc"
}

# ============================================================== dispatch

case "$CMD" in
    status)    cmd_status ;;
    snapshots) cmd_snapshots ;;
    run)       cmd_run ;;
    check)     cmd_check ;;
    schedule)  cmd_schedule ;;
    history)   cmd_history ;;
    log)       cmd_log ;;
    config)    cmd_config ;;
    exec)      cmd_exec ;;
    forget)    cmd_forget ;;
    restore)   cmd_restore ;;
    unlock)    cmd_unlock ;;
    ls)        cmd_ls ;;
    find)      cmd_find ;;
    publish|unpublish) cmd_publish ;;
esac
