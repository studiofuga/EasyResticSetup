#!/bin/sh
# =============================================================================
#  nas-fleet-status.sh - one view of every machine's backup, from the NAS.
#
#  Run it ON THE NAS, as a user with sudo rights:
#      sudo sh nas-fleet-status.sh
#
#  Or from any client, without copying it over:
#      ssh <admin>@<nas> 'sudo sh -s' < nas-fleet-status.sh
#
#  It needs NO repository password, and that is the point: the four repositories
#  keep their separate keys, and this script never sees them. What it can read
#  comes from file names and timestamps, not from encrypted content:
#
#      * how many snapshots each machine has   (files in <repo>/snapshots/)
#      * when the newest one was written       (mtime of the newest such file)
#      * how big each repository is
#      * locks left behind by interrupted runs (files in <repo>/locks/)
#
#  What it CANNOT tell you, because restic encrypts everything inside: what a
#  snapshot contains, whether the repository passes an integrity check, or
#  anything about a run that failed before writing a snapshot. For that, run
#  restic-ctl on the machine itself.
#
#  A machine whose newest snapshot is older than the warning threshold is the
#  signal to go and look: on a daily schedule, a backup that fails repeatedly
#  shows up here as silence, not as an error.
# =============================================================================
set -u

HOMES='/volume1/homes'
REPO_DIR='restic-repo'          # also tries homes/<user>/restic-repo for old layouts
WARN_HOURS=30
CRIT_HOURS=54
SHOW_SIZE=1

usage() {
    cat <<EOF
nas-fleet-status.sh - how fresh is every machine's backup, seen from the NAS.

Usage: sudo sh nas-fleet-status.sh [options]

  Runs ON THE NAS, as an admin account, over SSH. It finds every restic repository
  under the per-user homes and reports the newest snapshot's age for each, so one
  command answers "is anything not backing up" for the whole fleet.

  It holds no repository passwords and needs none: the age of a snapshot is the
  mtime of the newest file under the repository's snapshots/ directory, which is
  readable without being able to decrypt anything. So this can be run from an
  account that cannot read a single backed-up byte.

  --homes DIR      where the per-user homes live (default: $HOMES)
  --warn HOURS     warn above this snapshot age (default: $WARN_HOURS)
  --crit HOURS     critical above this age (default: $CRIT_HOURS)
  --no-size        skip du, which is the slow part on a big repository
  -h, --help       this text

  Defaults of 30 and 54 hours assume a daily backup: 30 h means one run has been
  missed, 54 h means two.

Exit code: 0 all machines fresh, 1 at least one stale, 2 nothing found.
  The exit code is there so this can be the check behind a cron job or a monitor.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --homes)   HOMES="$2"; shift 2 ;;
        --warn)    WARN_HOURS="$2"; shift 2 ;;
        --crit)    CRIT_HOURS="$2"; shift 2 ;;
        --no-size) SHOW_SIZE=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# Escapes built with printf, not $'...': that is a bash extension, and DSM's /bin/sh
# may be busybox ash, which would print the literal characters instead.
if [ -t 1 ]; then
    ESC="$(printf '\033')"
    C_OK="${ESC}[32m"; C_WARN="${ESC}[33m"; C_ERR="${ESC}[31m"
    C_DIM="${ESC}[90m"; C_W="${ESC}[97m"; C_OFF="${ESC}[0m"
else
    C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_W=''; C_OFF=''
fi

[ "$(id -u)" = 0 ] || { echo 'run this with sudo: the homes are not world-readable.' >&2; exit 2; }
[ -d "$HOMES" ] || { echo "no such directory: $HOMES" >&2; exit 2; }

NOW="$(date +%s)"
WARN_SEC=$((WARN_HOURS * 3600))
CRIT_SEC=$((CRIT_HOURS * 3600))

printf '\n  %srestic fleet - %s%s      %s%s%s\n' \
    "$C_W" "$(hostname)" "$C_OFF" "$C_DIM" "$(date '+%Y-%m-%d %H:%M')" "$C_OFF"
printf '  %sno repository passwords are used; ages come from file timestamps%s\n\n' "$C_DIM" "$C_OFF"

printf '  %-22s %6s  %-17s %-11s %8s %s\n' \
    'MACHINE' 'SNAPS' 'NEWEST SNAPSHOT' 'AGE' 'SIZE' 'NOTES'
printf '  %s\n' '--------------------------------------------------------------------------------------'

found=0
stale=0

for home in "$HOMES"/*; do
    [ -d "$home" ] || continue
    user="$(basename "$home")"

    # Find the repository: the per-machine layout is <home>/restic-repo, but an older
    # machine may address it as homes/<user>/restic-repo, which is the same place.
    repo=''
    for candidate in "$home/$REPO_DIR" "$home/homes/$user/$REPO_DIR"; do
        if [ -f "$candidate/config" ] && [ -d "$candidate/snapshots" ]; then
            repo="$candidate"; break
        fi
    done
    [ -n "$repo" ] || continue
    found=$((found + 1))

    # One file per snapshot, named by its id, in a flat directory. Counting them and
    # reading the newest mtime needs no key: only the contents are encrypted.
    # Deliberately ls/stat/date and not "find -printf": DSM's userland is partly
    # busybox, where -printf is often missing.
    count="$(ls -1 "$repo/snapshots" 2>/dev/null | wc -l | tr -d ' ')"

    newest_epoch=0
    newest_file=''
    if [ "${count:-0}" -gt 0 ]; then
        newest_file="$(ls -t "$repo/snapshots" 2>/dev/null | head -n 1)"
        if [ -n "$newest_file" ]; then
            newest_epoch="$(stat -c %Y "$repo/snapshots/$newest_file" 2>/dev/null || echo 0)"
        fi
    fi

    if [ "${newest_epoch:-0}" -gt 0 ]; then
        newest="$(date -r "$repo/snapshots/$newest_file" '+%Y-%m-%d %H:%M' 2>/dev/null)"
        [ -n "$newest" ] || newest="epoch $newest_epoch"
        age=$((NOW - newest_epoch))
        if   [ "$age" -ge 86400 ]; then age_h="$((age / 86400))d $((age % 86400 / 3600))h"
        elif [ "$age" -ge 3600 ];  then age_h="$((age / 3600))h $((age % 3600 / 60))m"
        else age_h="$((age / 60))m"
        fi
        if   [ "$age" -gt "$CRIT_SEC" ]; then col="$C_ERR";  stale=$((stale + 1))
        elif [ "$age" -gt "$WARN_SEC" ]; then col="$C_WARN"; stale=$((stale + 1))
        else col="$C_OK"
        fi
    else
        newest='never'; age_h='-'; col="$C_ERR"; stale=$((stale + 1))
    fi

    size='-'
    [ "$SHOW_SIZE" = 1 ] && size="$(du -sh "$repo" 2>/dev/null | cut -f1)"

    # Locks are plain files too. One that is not being refreshed means a run died
    # without releasing it; the client scripts clear stale locks on the next run.
    notes=''
    locks="$(ls -1 "$repo/locks" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${locks:-0}" -gt 0 ]; then
        lock_file="$(ls -t "$repo/locks" 2>/dev/null | head -n 1)"
        lock_newest="$(stat -c %Y "$repo/locks/$lock_file" 2>/dev/null || echo "$NOW")"
        lock_age=$((NOW - ${lock_newest:-$NOW}))
        if [ "$lock_age" -gt 1800 ]; then
            notes="stale lock ($((lock_age / 60))m)"
        else
            notes='backup in progress'
        fi
    fi

    printf '  %-22s %6s  %s%-17s %-11s%s %8s %s%s%s\n' \
        "$user" "$count" "$col" "$newest" "$age_h" "$C_OFF" "$size" \
        "$C_DIM" "$notes" "$C_OFF"
done

printf '\n'

if [ "$found" = 0 ]; then
    printf '  %sNo restic repository found under %s.%s\n' "$C_ERR" "$HOMES" "$C_OFF"
    printf '  %sA repository is a directory holding "config" and "snapshots/".%s\n\n' "$C_DIM" "$C_OFF"
    exit 2
fi

if [ "$stale" = 0 ]; then
    printf '  %s%d machine(s), all with a snapshot newer than %sh.%s\n' \
        "$C_OK" "$found" "$WARN_HOURS" "$C_OFF"
else
    printf '  %s%d of %d machine(s) have no recent snapshot.%s\n' \
        "$C_WARN" "$stale" "$found" "$C_OFF"
    printf '  %sRun "restic-ctl status" and "restic-ctl history" on those machines: a%s\n' "$C_DIM" "$C_OFF"
    printf '  %srepeatedly failing backup shows up here only as missing snapshots.%s\n' "$C_DIM" "$C_OFF"
fi
printf '\n'

[ "$stale" = 0 ] || exit 1
exit 0
