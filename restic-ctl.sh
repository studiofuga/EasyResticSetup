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
#    history     table of recent runs, including failed ones
#    log         tail the backup log
#    config      the effective settings of this machine
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

usage() { sed -n '3,26p' "$0" | sed 's/^#//; s/^ //'; }

[ $# -gt 0 ] && case "$1" in
    status|snapshots|run|check|history|log|config) CMD="$1"; shift ;;
    exec|forget|restore|unlock|ls|find)            CMD="$1"; shift ;;
    -h|--help) usage; exit 0 ;;
esac

# The wrapper subcommands take arbitrary restic arguments, so anything this
# script does not recognise is collected in REST and handed to restic verbatim.
while [ $# -gt 0 ]; do
    case "$1" in
        --deep)    DEEP=1; shift ;;
        --data)    DATA=1; shift ;;
        --follow)  FOLLOW=1; shift ;;
        --no-wait) NOWAIT=1; shift ;;
        --yes)     YES=1; shift ;;
        --target)  TARGET="$2"; shift 2 ;;
        --count)   COUNT="$2"; shift 2 ;;
        --base)    BASE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *)
            case "$CMD" in
                exec|forget|restore|ls|find) REST="$REST $1"; shift ;;
                *) echo "unknown option: $1" >&2; exit 2 ;;
            esac ;;
    esac
done

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

do_check() {
    if [ "${1:-0}" = 1 ]; then
        field 'Running' 'restic check --read-data-subset 5%' "$C_DIM"
        cont 'This re-downloads 5% of the data blobs and can take a while.' "$C_DIM"
        out="$(restic_ check --read-data-subset 5%)"
    else
        field 'Running' 'restic check' "$C_DIM"
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
    [ "$DATA" = 1 ] || \
        printf '\n  %s--data also re-reads 5%% of the data blobs (slower, catches bit rot).%s\n' \
            "$C_DIM" "$C_OFF"
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

    head_ 'Files'
    for pair in "Log:$LOG" "Excludes:$EXCLUDE_FILE" "Password:$RESTIC_PASSWORD_FILE" \
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

# ============================================================== dispatch

case "$CMD" in
    status)    cmd_status ;;
    snapshots) cmd_snapshots ;;
    run)       cmd_run ;;
    check)     cmd_check ;;
    history)   cmd_history ;;
    log)       cmd_log ;;
    config)    cmd_config ;;
    exec)      cmd_exec ;;
    forget)    cmd_forget ;;
    restore)   cmd_restore ;;
    unlock)    cmd_unlock ;;
    ls)        cmd_ls ;;
    find)      cmd_find ;;
esac
