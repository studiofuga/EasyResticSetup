#!/bin/bash
# =============================================================================
#  setup-restic-backup.sh
#
#  Sets up scheduled restic backups from this Linux machine to a Synology NAS
#  over SFTP. Linux counterpart of Setup-ResticBackup.ps1; same 9 steps, same
#  layout, and it generates the same NAS-side provisioning script.
#
#      1  Check prerequisites (root, restic, ssh, sftp, ssh-keygen, ssh-keyscan)
#      2  Create /etc/restic, owned by root, mode 700
#      3  Write config.json, ssh_config, excludes.txt, restic-backup.sh
#      4  Generate the SSH key, the repository password, the NAS script
#      5  Trust the NAS host key (fingerprint shown for confirmation)
#      6  Verify authentication and write access  <-- manual gate
#      7  Initialise the restic repository
#      8  Install and enable the systemd service and timer
#      9  Print the summary
#
#  Idempotent: re-running is safe, every step detects what is already in place.
#
#  Usage:
#      sudo ./setup-restic-backup.sh --nas-host nas.example.ts.net
#      sudo ./setup-restic-backup.sh --from 6
#      sudo ./setup-restic-backup.sh --nas-setup      # only the NAS script
#      sudo ./setup-restic-backup.sh --help
# =============================================================================
set -u

# ---- defaults ---------------------------------------------------------------
# No default on purpose: nothing site-specific is baked into this script. The NAS
# address is asked for on a first run and stored in config.json, which is not in
# version control.
NAS_HOST=''
NAS_USER=''                       # derived: restic-<hostname>
NAS_PORT=22
REPO_PATH=''                      # default: homes/<NAS_USER>/restic-repo
HOST_ALIAS='nas-restic'
BASE='/etc/restic'
BACKUP_PATHS='/home /etc'
KEEP_DAILY=14
KEEP_WEEKLY=8
KEEP_MONTHLY=12
ON_CALENDAR='daily'
# Second chance the same day, for a run that was interrupted or skipped on battery.
RETRY_CALENDAR='*-*-* 19:17'
FROM=1
ONLY=0
SKIP_TIMER=0
NAS_SETUP_ONLY=0
FORCE_EXCLUDES=0
ACCEPT_CHANGES=0

usage() {
    sed -n '2,26p' "$0" | sed 's/^#//; s/^ //'
    cat <<'EOF'

Options:
  --nas-host HOST     NAS hostname or IP. No default: asked for on a first run,
                      then read from config.json
  --nas-user USER     Dedicated Synology user (default: restic-<hostname>)
  --nas-port PORT     SSH port (default: 22)
  --repo-path PATH    Repository path relative to the SFTP root
                      (default: home/restic-repo -- "home" singular is DSM's
                      alias for the account's own home; "homes" plural is the
                      shared folder and needs a permission a backup-only
                      account normally lacks)
  --backup-paths "A B"  Paths to back up (default: "/home /etc")
  --on-calendar SPEC  systemd OnCalendar value (default: daily)
  --retry-calendar S  second, same-day attempt for an interrupted run
  --from N            Start at step N
  --only N            Run only step N
  --skip-timer        Do not install the systemd units
  --nas-setup         Only write the NAS provisioning script, then exit
  -h, --help          This text
EOF
}

# GIVEN records which options were typed, so a stored value can be told apart from a
# default further down.
GIVEN=''
while [ $# -gt 0 ]; do
    case "$1" in
        --nas-host)     NAS_HOST="$2";     GIVEN="$GIVEN nas-host";     shift 2 ;;
        --nas-user)     NAS_USER="$2";     GIVEN="$GIVEN nas-user";     shift 2 ;;
        --nas-port)     NAS_PORT="$2";     GIVEN="$GIVEN nas-port";     shift 2 ;;
        --repo-path)    REPO_PATH="$2";    GIVEN="$GIVEN repo-path";    shift 2 ;;
        --backup-paths) BACKUP_PATHS="$2"; GIVEN="$GIVEN backup-paths"; shift 2 ;;
        --on-calendar)  ON_CALENDAR="$2";  GIVEN="$GIVEN on-calendar";  shift 2 ;;
        --retry-calendar) RETRY_CALENDAR="$2"; GIVEN="$GIVEN retry-calendar"; shift 2 ;;
        --from)         FROM="$2"; shift 2 ;;
        --only)         ONLY="$2"; shift 2 ;;
        --skip-timer)   SKIP_TIMER=1; shift ;;
        --nas-setup)    NAS_SETUP_ONLY=1; shift ;;
        --force-excludes) FORCE_EXCLUDES=1; shift ;;
        --accept-changes) ACCEPT_CHANGES=1; shift ;;
        --base)         BASE="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)              echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

CONFIG="$BASE/config.json"
LEGACY_ENV="$BASE/settings.env"

# Which options the caller actually typed. A stored value must survive a re-run that
# does not mention it: on one machine, re-running a single step without --nas-user
# silently repointed it at another machine's NAS account - a wrong but valid value
# that fails no check.
given() { case " $GIVEN " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Read one dotted key out of config.json. python3 only; there is no fallback because
# the progress reporting already depends on it.
cfg() {
    [ -f "$CONFIG" ] || { echo ''; return; }
    python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
for k in sys.argv[2].split("."):
    if not isinstance(d, dict) or k not in d:
        raise SystemExit
    d = d[k]
if isinstance(d, list):
    print(" ".join(str(x) for x in d))
elif d is not None:
    print(d)' "$CONFIG" "$1" 2>/dev/null
}

# Machines set up before config.json existed keep their answers in settings.env, which
# holds the composed repository string rather than its parts - so the host, user and
# repo path are recovered from it and from ssh/config. An existing machine therefore
# never has to have its parameters retyped.
migrate_legacy() {
    [ -f "$LEGACY_ENV" ] || return 1
    # shellcheck source=/dev/null
    . "$LEGACY_ENV"
    m_alias="${HOST_ALIAS:-nas-restic}"
    m_path="$(printf '%s' "${RESTIC_REPOSITORY:-}" | sed -n 's/^sftp:[^:]*:\(.*\)$/\1/p')"
    m_host=''; m_user=''; m_port=22
    if [ -f "$BASE/ssh/config" ]; then
        m_host="$(awk '/^[[:space:]]*HostName/ {print $2; exit}' "$BASE/ssh/config")"
        m_user="$(awk '/^[[:space:]]*User/ {print $2; exit}' "$BASE/ssh/config")"
        p="$(awk '/^[[:space:]]*Port/ {print $2; exit}' "$BASE/ssh/config")"
        [ -n "$p" ] && m_port="$p"
    fi
    [ -n "$m_host" ] && [ -n "$m_user" ] && [ -n "$m_path" ] || return 1

    NAS_HOST="$m_host"; NAS_USER="$m_user"; NAS_PORT="$m_port"
    HOST_ALIAS="$m_alias"; REPO_PATH="$m_path"
    BACKUP_PATHS="${BACKUP_PATHS:-$BACKUP_PATHS}"
    KEEP_DAILY="${KEEP_DAILY:-14}"; KEEP_WEEKLY="${KEEP_WEEKLY:-8}"
    KEEP_MONTHLY="${KEEP_MONTHLY:-12}"
    MIGRATED_FROM="$LEGACY_ENV"
    return 0
}

MIGRATED_FROM=''
if [ -f "$CONFIG" ]; then
    given nas-host  || { v="$(cfg nas.host)";           [ -n "$v" ] && NAS_HOST="$v"; }
    given nas-user  || { v="$(cfg nas.user)";           [ -n "$v" ] && NAS_USER="$v"; }
    given nas-port  || { v="$(cfg nas.port)";           [ -n "$v" ] && NAS_PORT="$v"; }
    given repo-path || { v="$(cfg nas.repoPath)";       [ -n "$v" ] && REPO_PATH="$v"; }
    v="$(cfg nas.hostAlias)";                           [ -n "$v" ] && HOST_ALIAS="$v"
    given backup-paths || { v="$(cfg backupPaths)";     [ -n "$v" ] && BACKUP_PATHS="$v"; }
    given on-calendar    || { v="$(cfg schedule.onCalendar)";    [ -n "$v" ] && ON_CALENDAR="$v"; }
    given retry-calendar || { v="$(cfg schedule.retryCalendar)"; [ -n "$v" ] && RETRY_CALENDAR="$v"; }
    v="$(cfg retention.daily)";   [ -n "$v" ] && KEEP_DAILY="$v"
    v="$(cfg retention.weekly)";  [ -n "$v" ] && KEEP_WEEKLY="$v"
    v="$(cfg retention.monthly)"; [ -n "$v" ] && KEEP_MONTHLY="$v"
else
    migrate_legacy || true
fi

# Derived, not defaulted: one NAS account per machine, named after the machine, so
# nothing about any particular site is written into this script.
[ -n "$NAS_USER" ]  || NAS_USER="restic-$(hostname -s | tr '[:upper:]' '[:lower:]')"

# The NAS address is the one value that can be neither derived nor sensibly defaulted,
# so a first run asks for it. Deliberate: this script carries no site-specific values,
# and the answer goes to config.json, which stays out of version control.
if [ -z "$NAS_HOST" ]; then
    if [ ! -t 0 ]; then
        echo 'No NAS address. Pass --nas-host <hostname-or-ip>.' >&2
        echo 'It is needed once; later runs read it from config.json.' >&2
        exit 2
    fi
    printf '\n  This machine has no stored configuration yet.\n'
    printf '  The NAS address is not defaulted on purpose; it is stored after this run.\n\n'
    printf '    NAS hostname or IP: '
    read -r NAS_HOST
    NAS_HOST="$(printf '%s' "$NAS_HOST" | tr -d '[:space:]')"
    [ -n "$NAS_HOST" ] || { printf '\n  Nothing entered, aborting.\n\n'; exit 2; }
fi
# "home" (singular) is DSM's per-user alias for the logged-in account's own home, and it
# is reachable without any permission on the "homes" shared folder - which a backup-only
# account normally does not have. Going through homes/<user> instead fails with a bare
# "permission denied" even when the home's own ACL is correct.
[ -n "$REPO_PATH" ] || REPO_PATH='home/restic-repo'

SSH_DIR="$BASE/ssh"
KEY_FILE="$SSH_DIR/id_ed25519"
SSH_CONFIG="$SSH_DIR/config"
KNOWN_HOSTS="$SSH_DIR/known_hosts"
PASSWORD_FILE="$BASE/password"
EXCLUDE_FILE="$BASE/excludes.txt"
BACKUP_SCRIPT='/usr/local/bin/restic-backup.sh'
REPOSITORY="sftp:$HOST_ALIAS:$REPO_PATH"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---- output helpers ---------------------------------------------------------
if [ -t 1 ]; then
    C_STEP=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'
    C_FAIL=$'\033[31m'; C_DIM=$'\033[90m'; C_OFF=$'\033[0m'
else
    C_STEP=''; C_OK=''; C_WARN=''; C_FAIL=''; C_DIM=''; C_OFF=''
fi

step() { printf '\n%s[%s] %s%s\n' "$C_STEP" "$1" "$2" "$C_OFF"; }
ok()   { printf '    %sOK%s    %s\n' "$C_OK" "$C_OFF" "$1"; }
info() { printf '    %s      %s%s\n' "$C_DIM" "$1" "$C_OFF"; }
warn() { printf '    %sWARN%s  %s\n' "$C_WARN" "$C_OFF" "$1"; }
fail() { printf '    %sFAIL%s  %s\n' "$C_FAIL" "$C_OFF" "$1"; }
die()  { fail "$1"; exit 1; }

should_run() {
    if [ "$ONLY" -gt 0 ]; then [ "$1" -eq "$ONLY" ]; else [ "$1" -ge "$FROM" ]; fi
}

# =============================================================================
#  NAS provisioning script generator
#  Everything that has to happen on the NAS lives in the file this writes, so
#  replicating on another client is: run steps 1-4 here, run that file there.
# =============================================================================
write_nas_provision_script() {
    [ -f "$KEY_FILE.pub" ] || { fail "public key missing: run steps 1-4 first"; return 1; }

    NAS_PROVISION="$SCRIPT_DIR/nas-provision-$NAS_USER.sh"
    PUBKEY_CONTENT="$(cat "$KEY_FILE.pub")"

    cat > "$NAS_PROVISION" <<PROVISION_TEMPLATE
#!/bin/sh
# ---------------------------------------------------------------------------
# Provisions the restic backup account for client "$(hostname -s)" on this
# Synology NAS. Generated by setup-restic-backup.sh -- regenerate, do not edit.
#
# Copy it to the NAS and run it there as a user with sudo rights:
#     sudo sh nas-provision-$NAS_USER.sh
#
# Idempotent. It does NOT create the DSM user; it tells you what to set.
# ---------------------------------------------------------------------------
set -u

NAS_USER='$NAS_USER'
PUBKEY='$PUBKEY_CONTENT'
REPO_PATH='$REPO_PATH'
PROVISION_TEMPLATE

    # Second chunk unexpanded: the shell script's own \$variables must survive.
    cat >> "$NAS_PROVISION" <<'PROVISION_BODY'
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
# A home created by hand stays in "Linux mode", with no ACL at all. Homes DSM
# creates carry a full-control ACE for their owner, and restic needs it to
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
echo 'Back on the client, continue with:  sudo ./setup-restic-backup.sh --from 6'
PROVISION_BODY

    chmod 0644 "$NAS_PROVISION"
    return 0
}

show_nas_provision_instructions() {
    write_nas_provision_script || return 0
    name="$(basename "$NAS_PROVISION")"
    printf '\n'
    printf '    %sEverything the NAS needs is in this generated script:%s\n' "$C_WARN" "$C_OFF"
    printf '      %s\n\n' "$NAS_PROVISION"
    printf '    Copy it over and run it there, with an admin account:\n'
    printf '      scp %s <admin>@%s:/tmp/%s\n' "$NAS_PROVISION" "$NAS_HOST" "$name"
    printf '      ssh <admin>@%s\n' "$NAS_HOST"
    printf '      sudo sh /tmp/%s && rm /tmp/%s\n\n' "$name" "$name"
    info 'It checks the DSM user, the home ownership and mode, the DSM ACL and'
    info 'authorized_keys, fixes what is wrong, and prints the final state.'
    printf '\n    %sThen: sudo ./setup-restic-backup.sh --from 6%s\n' "$C_WARN" "$C_OFF"
}

# =============================================================================
printf '\n=== restic backup setup ===\n'
info "NAS          $NAS_USER@$NAS_HOST:$NAS_PORT"
info "Repository   $REPOSITORY"
info "Local base   $BASE"
info "Backup paths $BACKUP_PATHS"

if [ -n "$MIGRATED_FROM" ]; then
    info "Config       migrated from $(basename "$MIGRATED_FROM")"
elif [ -f "$CONFIG" ]; then
    info "Config       $CONFIG"
else
    info 'Config       none yet, this looks like a first run'
fi

[ "$(id -u)" = 0 ] || die 'run this with sudo'

# An explicit change to any of these repoints the repository. It is not something a
# check can validate: pointing a machine at another machine's NAS account is a wrong
# but perfectly valid value, and it silently writes into the wrong repository instead
# of failing. So it is confirmed by a human, once, rather than detected afterwards.
if [ -f "$CONFIG" ]; then
    changes=''
    for pair in "nas.user:$NAS_USER:NAS_USER" "nas.host:$NAS_HOST:NAS_HOST" \
                "nas.repoPath:$REPO_PATH:REPO_PATH"; do
        key="${pair%%:*}"; rest="${pair#*:}"
        new="${rest%%:*}"; label="${rest##*:}"
        old="$(cfg "$key")"
        if [ -n "$old" ] && [ "$old" != "$new" ]; then
            changes="$changes
      $(printf '%-12s %s  ->  %s' "$label" "$old" "$new")"
        fi
    done
    if [ -n "$changes" ]; then
        printf '\n'
        warn 'This changes where the repository lives:'
        printf '%s\n\n' "$changes"
        info 'Correct when you are moving this machine to a different NAS account or'
        info 'path. Wrong if an option was left out by mistake: the backup would then'
        info 'write into another repository, which fails no check.'
        if [ "$ACCEPT_CHANGES" = 1 ]; then
            info 'Accepted via --accept-changes.'
        else
            printf '    Type CHANGE to continue, anything else to abort: '
            read -r answer
            if [ "$answer" != 'CHANGE' ]; then
                printf '\n'
                fail 'aborted, nothing was changed'
                info 'Re-run without those options to keep the stored values.'
                printf '\n'
                exit 1
            fi
        fi
    fi
fi

if [ "$NAS_SETUP_ONLY" -eq 1 ]; then
    step 0 'NAS provisioning script'
    show_nas_provision_instructions
    printf '\n'
    exit 0
fi

# ============================================================ 1. prerequisites
if should_run 1; then
    step 1 'Prerequisites'
    missing=0
    for exe in restic ssh sftp ssh-keygen ssh-keyscan; do
        if command -v "$exe" >/dev/null 2>&1; then
            ok "$exe -> $(command -v "$exe")"
        else
            fail "$exe not found in PATH"; missing=1
        fi
    done
    command -v systemctl >/dev/null 2>&1 || { fail 'systemctl not found'; missing=1; }

    if [ "$missing" -eq 1 ]; then
        printf '\n'
        info 'Debian/Ubuntu:  apt install restic openssh-client'
        exit 1
    fi
    info "$(restic version)"

    if command -v tailscale >/dev/null 2>&1; then
        info 'Tailscale present; the backup runs as root via systemd, which keeps'
        info 'working across logouts, so no extra setting is needed here.'
    elif case "$NAS_HOST" in *.ts.net) true ;; *) false ;; esac; then
        warn 'NAS host is a Tailscale name but tailscale was not found in PATH.'
    fi
fi

# ============================================================== 2. directories
if should_run 2; then
    step 2 'Directory layout and permissions'
    for d in "$BASE" "$SSH_DIR" "$BASE/cache"; do
        if [ -d "$d" ]; then info "exists $d"; else mkdir -p "$d" && ok "created $d"; fi
    done
    chown -R root:root "$BASE"
    chmod 700 "$BASE" "$SSH_DIR" "$BASE/cache"
    ok 'owned by root, mode 700 (the backup runs as root)'
fi

# =========================================================== 3. configuration
if should_run 3; then
    step 3 'Configuration files'

    # config.json: the one place this machine's answers live. Same schema as the Windows
    # installer writes, read by this script, by restic-backup.sh and by restic-ctl, so
    # there is a single source of truth instead of parameters re-typed per run.
    # The repository string is NOT stored: it is composed from hostAlias and repoPath by
    # every reader, so it cannot drift from its parts.
    BACKUP_PATHS_JSON="$(printf '%s' "$BACKUP_PATHS" | python3 -c '
import json, sys
print(json.dumps(sys.stdin.read().split()))')"
    cat > "$CONFIG" <<EOF
{
  "configVersion": 1,
  "machine": "$(hostname -s)",
  "updated": "$(date '+%Y-%m-%dT%H:%M:%S%z')",
  "nas": {
    "host": "$NAS_HOST",
    "user": "$NAS_USER",
    "port": $NAS_PORT,
    "hostAlias": "$HOST_ALIAS",
    "repoPath": "$REPO_PATH"
  },
  "backupPaths": $BACKUP_PATHS_JSON,
  "retention": { "daily": $KEEP_DAILY, "weekly": $KEEP_WEEKLY, "monthly": $KEEP_MONTHLY },
  "schedule": { "onCalendar": "$ON_CALENDAR", "retryCalendar": "$RETRY_CALENDAR" },
  "paths": { "base": "$BASE", "tools": "/usr/local/bin" }
}
EOF
    chmod 600 "$CONFIG"
    if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CONFIG" 2>/dev/null; then
        die "the config.json just written is not valid JSON: $CONFIG"
    fi
    ok 'config.json'

    # The legacy file is renamed, not deleted: nothing should read it any more, and it
    # stays recoverable if the migration got something wrong.
    if [ -f "$LEGACY_ENV" ]; then
        mv -f "$LEGACY_ENV" "$LEGACY_ENV.migrated"
        info 'settings.env migrated to config.json (kept as settings.env.migrated)'
    fi

    cat > "$SSH_CONFIG" <<EOF
# Used only by restic. Passed explicitly with -F so it never depends on
# /root/.ssh/config, which stays free for interactive use.
Host $HOST_ALIAS
    HostName $NAS_HOST
    User $NAS_USER
    Port $NAS_PORT
    IdentityFile $KEY_FILE
    IdentitiesOnly yes
    UserKnownHostsFile $KNOWN_HOSTS
    BatchMode yes
    ServerAliveInterval 60
    ServerAliveCountMax 240
EOF
    chmod 600 "$SSH_CONFIG"
    ok 'ssh/config'

    # Not overwritten by default: this file is meant to be tuned by hand.
    # --force-excludes replaces it with the current template, keeping a .bak, which is
    # how a machine set up earlier picks up new template rules.
    if [ -f "$EXCLUDE_FILE" ] && [ "$FORCE_EXCLUDES" = 0 ]; then
        info 'excludes.txt already present, left untouched (--force-excludes to replace)'
    else
        if [ -f "$EXCLUDE_FILE" ]; then
            cp -f "$EXCLUDE_FILE" "$EXCLUDE_FILE.bak"
            info 'previous excludes.txt kept as excludes.txt.bak'
        fi
        cat > "$EXCLUDE_FILE" <<'EOF'
# Absolute patterns anchor to /; bare names match at any depth.
# Check the effect with:  restic-backup.sh --dry-run

# =============================================================================
#  Virtual machine disk images
#
#  Matched by extension, not by folder, so this holds whatever the VMs are
#  called and wherever they live. On one Windows machine here the first backup was
#  over 1 TB of VM images, about 90% of the whole snapshot.
#
#  Worth excluding even with room to spare. A disk image of a running VM is
#  captured mid-write and is usually not restorable, and it changes as a whole,
#  so every run re-uploads the whole file. Back a VM up by exporting it, or from
#  inside the guest - not by copying its live disk.
# =============================================================================
*.qcow2
*.qed
*.vdi
*.vmdk
*.vhd
*.vhdx
*.raw

# --- Downloads: re-downloadable by definition. Note the flip side: anything
# --- parked here and meant to be kept is NOT backed up.
/home/*/Downloads
/home/*/Scaricati

# =============================================================================
#  Cloud-synced folders - GENERAL RULE
#
#  Anything kept in sync with a cloud service is excluded. Each service is
#  responsible for backing up its own content; restic backs up what lives only
#  on this machine. Beyond the duplication: the same bytes would otherwise be
#  stored once per machine that syncs them.
#
#  The flip side, stated plainly: for these folders the service IS the backup.
#  A file deleted and purged there is gone, with no restic snapshot behind it.
#
#  Add new services to this list as they appear.
# =============================================================================
/home/*/Nextcloud
/home/*/ownCloud
/home/*/Dropbox
/home/*/OneDrive
/home/*/Google Drive
/home/*/GoogleDrive
/home/*/Insync
/home/*/pCloudDrive
/home/*/MEGA
/home/*/Seafile
/home/*/Sync
# The sync clients' own databases and caches, re-creatable either way:
/home/*/.local/share/Nextcloud
/home/*/.config/Nextcloud
/home/*/.dropbox
/home/*/.dropbox-dist
/home/*/.config/Insync
/home/*/.cache/megasync

# --- caches and runtime state ---
/home/*/.cache
/home/*/.local/share/Trash
/home/*/.thumbnails
/var/tmp
/var/cache

# --- containers and VMs (large, re-creatable) ---
/home/*/.local/share/containers
/home/*/.local/share/libvirt
/home/*/VirtualBox VMs

# --- re-downloadable toolchains and package caches ---
/home/*/.gradle/caches
/home/*/.gradle/wrapper/dists
/home/*/.m2/repository
/home/*/.cargo/registry
/home/*/.rustup/toolchains
/home/*/.npm
/home/*/.nuget/packages
/home/*/Android/Sdk
/home/*/.android/avd
/home/*/.platformio/packages
/home/*/.ccache
/home/*/.conan2/p

# --- build output inside git repos (any depth) ---
node_modules
__pycache__
.venv
.ccls-cache
.cxx
# Generic names: fine in code trees, but they also match any directory called
# "build"/"target" elsewhere. Use absolute patterns if that is a problem.
build
build-*
target
cmake-build-*
EOF
        ok 'excludes.txt'
    fi

    cat > "$BACKUP_SCRIPT" <<'BACKUP_SCRIPT_EOF'
#!/bin/bash
# restic-backup.sh - scheduled restic backup to the Synology NAS over SFTP.
# Generated by setup-restic-backup.sh. Edit /etc/restic/config.json instead.
#
#   restic-backup.sh              normal run (what the systemd service does)
#   restic-backup.sh --dry-run    list what would be backed up, no upload
#   restic-backup.sh --init       one-time: create the repository
set -u

BASE='/etc/restic'
CONFIG="$BASE/config.json"
LOG='/var/log/restic-backup.log'
PROGRESS="$BASE/progress.json"
LAST_RUN="$BASE/last-run.json"
HISTORY="$BASE/history.jsonl"
[ -r "$CONFIG" ] || { echo "missing $CONFIG - run setup-restic-backup.sh" >&2; exit 1; }

cfg() {
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[k]
print(" ".join(str(x) for x in d) if isinstance(d, list) else d)' "$CONFIG" "$1"
}

HOST_ALIAS="$(cfg nas.hostAlias)"
REPO_PATH="$(cfg nas.repoPath)"
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

MODE='backup'
case "${1:-}" in
    --init)    MODE='init' ;;
    --dry-run) MODE='dryrun' ;;
    '')        ;;
    *)         echo "unknown option: $1" >&2; exit 2 ;;
esac

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# Rotate at 10MB so the log cannot grow without bound between logrotate runs.
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 10485760 ]; then
    mv -f "$LOG" "$LOG.old"
fi
touch "$LOG"; chmod 600 "$LOG"

SFTP_COMMAND="ssh -F $SSH_CONFIG -o BatchMode=yes $HOST_ALIAS -s sftp"

run_restic() {
    log ">> restic $*"
    restic -o "sftp.command=$SFTP_COMMAND" "$@" >> "$LOG" 2>&1
}

write_json() {
    # Write then move: a reader must never catch a half-written file.
    printf '%s\n' "$2" > "$1.tmp" && mv -f "$1.tmp" "$1"
}

# restic emits --json status objects even when its output is redirected, which is the
# only way to see progress from a timer run: no terminal, no progress bar. Status
# objects arrive several times a second, so they are throttled to a file rather than
# written to the log. Needs python3 or jq; without either, progress is skipped and
# the backup still runs.
filter_json_progress() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -u -c '
import json, os, sys, time
progress, logpath = sys.argv[1], sys.argv[2]
started = time.time()
last_file, last_log = 0.0, 0.0
def logline(msg):
    with open(logpath, "a") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    if not raw.startswith("{"):
        logline(raw)
        continue
    try:
        o = json.loads(raw)
    except ValueError:
        logline(raw)
        continue
    t = o.get("message_type")
    if t == "status":
        now = time.time()
        if now - last_file >= 15:
            last_file = now
            rec = {
                "updated": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                "startedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(started)),
                "pid": os.getppid(),
                "percentDone": round(o.get("percent_done", 0) * 100, 1),
                "filesDone": o.get("files_done"),
                "totalFiles": o.get("total_files"),
                "bytesDone": o.get("bytes_done"),
                "totalBytes": o.get("total_bytes"),
                "secondsElapsed": o.get("seconds_elapsed"),
                "secondsRemaining": o.get("seconds_remaining"),
                "currentFile": (o.get("current_files") or [None])[0],
            }
            tmp = progress + ".tmp"
            with open(tmp, "w") as f:
                json.dump(rec, f, indent=2)
            os.replace(tmp, progress)
        if now - last_log >= 300:
            last_log = now
            logline("progress %.1f%% - %s of %s files, %.1f of %.1f GB" % (
                o.get("percent_done", 0) * 100, o.get("files_done"), o.get("total_files"),
                o.get("bytes_done", 0) / 1e9, o.get("total_bytes", 0) / 1e9))
    elif t == "error":
        logline("error: %s [%s]" % (o.get("error", {}).get("message"), o.get("item")))
    elif t == "summary":
        # Handed to the shell through a file: the pipeline runs in a subshell.
        with open(progress + ".summary", "w") as f:
            json.dump(o, f)
        logline("summary: snapshot %s, %s new / %s changed files, %.2f GB added" % (
            o.get("snapshot_id"), o.get("files_new"), o.get("files_changed"),
            o.get("data_added", 0) / 1e9))
' "$PROGRESS" "$LOG"
    else
        # No python3: keep the raw JSON out of the log, just record that we cannot parse it.
        log 'python3 not found: progress reporting disabled for this run'
        cat >> "$LOG"
    fi
}

if [ "$MODE" = 'init' ]; then
    log '===== repository init ====='
    run_restic init
    rc=$?
    log "init exit code $rc"
    exit $rc
fi

RUN_STARTED="$(date '+%Y-%m-%dT%H:%M:%S%z')"
RUN_EPOCH="$(date +%s)"

if [ "$MODE" = 'dryrun' ]; then
    log '===== backup started (dry run) ====='
else
    log '===== backup started ====='
fi

# Clear stale locks from an interrupted run (only removes locks with no live process)
run_restic unlock || true

rm -f "$PROGRESS.summary"
set -o pipefail
# shellcheck disable=SC2086
if [ "$MODE" = 'dryrun' ]; then
    restic -o "sftp.command=$SFTP_COMMAND" backup --json --dry-run --exclude-caches \
        --exclude-file "$EXCLUDE_FILE" --tag scheduled $BACKUP_PATHS 2>&1 | filter_json_progress
else
    restic -o "sftp.command=$SFTP_COMMAND" backup --json --exclude-caches \
        --exclude-file "$EXCLUDE_FILE" --tag scheduled $BACKUP_PATHS 2>&1 | filter_json_progress
fi
rc=$?
set +o pipefail
rm -f "$PROGRESS"

case "$rc" in
    0) log 'backup OK';       outcome='ok' ;;
    3) log 'backup completed with WARNINGS (some files could not be read)'
       outcome='warnings' ;;
    *) log "backup FAILED (exit $rc)"; outcome='failed' ;;
esac

# Recorded even on failure: the repository holds no trace of a backup that did not
# finish, so this file is the only history of failed runs.
if [ "$MODE" != 'dryrun' ]; then
    summary_json='null'
    [ -f "$PROGRESS.summary" ] && summary_json="$(cat "$PROGRESS.summary")"
    record="$(RUN_STARTED="$RUN_STARTED" RUN_EPOCH="$RUN_EPOCH" OUTCOME="$outcome" \
              RC="$rc" SUMMARY="$summary_json" python3 -c '
import json, os, socket, time
s = os.environ["SUMMARY"]
try:
    summary = json.loads(s)
except ValueError:
    summary = None
rec = {
    "startedAt": os.environ["RUN_STARTED"],
    "finishedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "durationSec": int(time.time()) - int(os.environ["RUN_EPOCH"]),
    "outcome": os.environ["OUTCOME"],
    "exitCode": int(os.environ["RC"]),
    "host": socket.gethostname(),
    "runAs": os.environ.get("USER") or "root",
}
if isinstance(summary, dict):
    rec.update({
        "snapshotId": summary.get("snapshot_id"),
        "filesNew": summary.get("files_new"),
        "filesChanged": summary.get("files_changed"),
        "dataAddedBytes": summary.get("data_added"),
        "filesProcessed": summary.get("total_files_processed"),
        "bytesProcessed": summary.get("total_bytes_processed"),
    })
print(json.dumps(rec, indent=2))
' 2>/dev/null)"
    [ -n "$record" ] || \
        record="{\"startedAt\":\"$RUN_STARTED\",\"outcome\":\"$outcome\",\"exitCode\":$rc}"
    write_json "$LAST_RUN" "$record"

    # last-run.json holds only the latest run, so failures would be forgotten as soon
    # as the next backup succeeds. This append-only file is the run history.
    printf '%s\n' "$record" | tr -d '\n' >> "$HISTORY"
    printf '\n' >> "$HISTORY"
    if [ "$(wc -l < "$HISTORY")" -gt 500 ]; then
        tail -n 500 "$HISTORY" > "$HISTORY.tmp" && mv -f "$HISTORY.tmp" "$HISTORY"
    fi
    chmod 600 "$HISTORY" 2>/dev/null || true
fi
rm -f "$PROGRESS.summary"

[ "$outcome" = 'failed' ] && exit "$rc"

if [ "$MODE" != 'dryrun' ]; then
    run_restic forget --prune \
        --keep-daily "$KEEP_DAILY" \
        --keep-weekly "$KEEP_WEEKLY" \
        --keep-monthly "$KEEP_MONTHLY"
    rc=$?
    [ "$rc" -eq 0 ] || { log "forget/prune FAILED (exit $rc)"; exit "$rc"; }
fi

log '===== backup finished ====='
exit 0
BACKUP_SCRIPT_EOF
    chmod 700 "$BACKUP_SCRIPT"
    ok "$BACKUP_SCRIPT"

    # restic-ctl needs no configuration of its own - it reads config.json - so it is
    # simply put on PATH when it is shipped alongside this installer.
    if [ -f "$SCRIPT_DIR/restic-ctl.sh" ]; then
        install -m 700 "$SCRIPT_DIR/restic-ctl.sh" /usr/local/bin/restic-ctl
        ok '/usr/local/bin/restic-ctl'
    else
        info 'restic-ctl.sh not found next to this script, skipping its install'
    fi
fi

# ==================================================== 4. key, password, NAS sh
if should_run 4; then
    step 4 'SSH key, repository password and NAS provisioning script'

    if [ -f "$KEY_FILE" ]; then
        info 'private key already present, kept'
    else
        ssh-keygen -t ed25519 -q -N '' -C "restic@$(hostname -s)" -f "$KEY_FILE" \
            || die 'ssh-keygen failed'
        ok 'ed25519 key generated (no passphrase: the timer runs unattended)'
    fi
    chmod 600 "$KEY_FILE"; chmod 644 "$KEY_FILE.pub"

    if [ -f "$PASSWORD_FILE" ]; then
        info 'repository password already present, kept'
    else
        umask 077
        head -c 32 /dev/urandom | base64 | tr -d '\n' > "$PASSWORD_FILE" \
            || die 'cannot write the password file'
        chmod 600 "$PASSWORD_FILE"
        ok 'repository password generated'
        printf '\n'
        warn 'Copy this password into your password manager NOW.'
        warn 'Without it the repository is unrecoverable, backups included.'
        printf '          %s\n' "$(cat "$PASSWORD_FILE")"
    fi

    if write_nas_provision_script; then
        ok "NAS provisioning script: $NAS_PROVISION"
        info 'Everything that has to happen on the NAS is in there. Copy it over'
        info 'and run it as an admin user with sudo, then come back to step 6.'
    fi
fi

# ============================================================== 5. NAS host key
if should_run 5; then
    step 5 'NAS host key'

    need_scan=1
    if [ -f "$KNOWN_HOSTS" ] && ssh-keygen -F "$NAS_HOST" -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
        info "host key for $NAS_HOST already trusted"
        need_scan=0
    fi

    if [ "$need_scan" -eq 1 ]; then
        scan="$(ssh-keyscan -p "$NAS_PORT" -t ed25519 "$NAS_HOST" 2>/dev/null)"
        [ -n "$scan" ] || die "ssh-keyscan got no answer from $NAS_HOST:$NAS_PORT"

        tmp="$(mktemp)"
        printf '%s\n' "$scan" > "$tmp"
        printf '\n    Host key fingerprint: %s\n' "$(ssh-keygen -lf "$tmp")"
        rm -f "$tmp"
        info 'Check it in DSM > Control Panel > Terminal & SNMP, or against the'
        info 'known_hosts of a machine that already talks to this NAS.'
        printf '    Trust this key? (yes/no) '
        read -r answer
        [ "$answer" = 'yes' ] || die 'host key not trusted, aborting'

        printf '%s\n' "$scan" >> "$KNOWN_HOSTS"
        chmod 600 "$KNOWN_HOSTS"
        ok "host key stored in $KNOWN_HOSTS"
    fi
fi

# ================================================= 6. authentication and write
if should_run 6; then
    step 6 'Key-based authentication and write access'

    # Tested with the sftp client, NOT with "ssh -s sftp": on a successful login
    # the latter hands the session to the SFTP subsystem and waits on stdin
    # forever. A batch file makes sftp connect, run one command and exit with a
    # usable status, and it exercises the same subsystem restic uses.
    tmp="$(mktemp)"
    printf 'pwd\n' > "$tmp"
    out="$(sftp -F "$SSH_CONFIG" -o BatchMode=yes -o ConnectTimeout=15 \
                -b "$tmp" "$HOST_ALIAS" 2>&1)"
    auth_rc=$?
    rm -f "$tmp"

    if [ "$auth_rc" -ne 0 ]; then
        printf '\n'
        fail 'the NAS did not accept the key'
        info "$(printf '%s' "$out" | tr '\n' ' ')"
        printf '\n'
        info 'sshd also refuses the key silently when the home, .ssh or'
        info 'authorized_keys are writable by group or other.'
        show_nas_provision_instructions
        exit 1
    fi

    ok "authenticated as $NAS_USER@$NAS_HOST with the dedicated key"
    remote_pwd="$(printf '%s' "$out" | grep -i 'working directory' | head -n 1)"
    [ -n "$remote_pwd" ] && { info "$remote_pwd"; info "Repository path is relative to this: $REPO_PATH"; }

    # Write probe: without it, a home the account cannot write into surfaces only
    # later as a bare "MkdirAll ...: permission denied" from restic init.
    repo_parent="$(dirname "$REPO_PATH")"
    probe="$repo_parent/.restic-write-probe"
    tmp="$(mktemp)"
    printf 'mkdir %s\nrmdir %s\n' "$probe" "$probe" > "$tmp"
    out="$(sftp -F "$SSH_CONFIG" -o BatchMode=yes -b "$tmp" "$HOST_ALIAS" 2>&1)"
    write_rc=$?
    rm -f "$tmp"

    if [ "$write_rc" -ne 0 ]; then
        printf '\n'
        fail "authentication works, but $NAS_USER cannot create directories under $repo_parent"
        info "$(printf '%s' "$out" | tr '\n' ' ')"
        printf '\n'
        info 'The account can log in but not write in its own home. Usually the home'
        info 'was created by hand rather than by DSM, so it has no ACL at all'
        info '("Linux mode") while DSM-created homes carry an owner ACE.'
        show_nas_provision_instructions
        exit 1
    fi
    ok "write access confirmed under $repo_parent"
fi

# ============================================================ 7. repository
if should_run 7; then
    step 7 'restic repository'
    if "$BACKUP_SCRIPT" --init >/dev/null 2>&1; then
        ok "repository ready at $REPOSITORY"
    else
        # --init fails when the repository already exists, which is fine; tell the
        # two cases apart by asking restic for the config.
        export RESTIC_REPOSITORY="$REPOSITORY" RESTIC_PASSWORD_FILE="$PASSWORD_FILE"
        if restic -o "sftp.command=ssh -F $SSH_CONFIG -o BatchMode=yes $HOST_ALIAS -s sftp" \
                  cat config >/dev/null 2>&1; then
            info 'repository already initialised'
        else
            fail 'restic init failed'
            info "see the tail of /var/log/restic-backup.log"
            tail -n 15 /var/log/restic-backup.log 2>/dev/null | sed 's/^/          /'
            exit 1
        fi
    fi
fi

# ============================================================== 8. systemd
if should_run 8 && [ "$SKIP_TIMER" -eq 0 ]; then
    step 8 'systemd service and timer'

    # systemd-inhibit stops the idle timer from suspending the machine mid-backup, which
    # would drop the SSH connection and fail the run. --what=idle and not idle:sleep on
    # purpose: blocking "sleep" outright would also veto a suspend the user asked for,
    # which is not ours to refuse. A lid close or an explicit suspend still interrupts
    # the backup; restic resumes on the next run.
    INHIBIT="$(command -v systemd-inhibit 2>/dev/null || true)"
    if [ -n "$INHIBIT" ]; then
        EXEC_START="$INHIBIT --what=idle --why=restic-backup --mode=block $BACKUP_SCRIPT"
        ok 'idle sleep will be inhibited while the backup runs'
    else
        EXEC_START="$BACKUP_SCRIPT"
        warn 'systemd-inhibit not found: an idle suspend can interrupt a backup'
    fi

    cat > /etc/systemd/system/restic-backup.service <<EOF
[Unit]
Description=restic backup to the Synology NAS
Documentation=file://$CONFIG
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$EXEC_START
Nice=10
IOSchedulingClass=idle
# Do not run on battery. The counterpart of the Windows task's default: a laptop
# should not spend its charge hashing a terabyte, and an interrupted run costs little
# because restic keeps the packs it has already uploaded.
ConditionACPower=true
# The whole point of restic here is to be userspace-only, so no sandboxing that
# would block reading arbitrary paths under $BACKUP_PATHS.
EOF

    # Two OnCalendar entries, not one. The second is the retry: if the first run was
    # interrupted - a suspend, the machine on battery, the NAS unreachable - this one
    # picks it up the same day instead of waiting until tomorrow. When the first run
    # succeeded the second is a fast incremental, so it costs almost nothing.
    #
    # Why not Restart=on-failure on the service: whether systemd permits Restart= with
    # Type=oneshot is something I could not confirm from the documentation, and a
    # setting that silently does nothing is worse than a second timer entry that
    # visibly works. Check "systemctl list-timers restic-backup.timer" to see both.
    cat > /etc/systemd/system/restic-backup.timer <<EOF
[Unit]
Description=Run the restic backup on a schedule

[Timer]
OnCalendar=$ON_CALENDAR
OnCalendar=$RETRY_CALENDAR
# Catch up after the machine was off at the scheduled time.
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now restic-backup.timer >/dev/null 2>&1
    ok "restic-backup.timer enabled (OnCalendar=$ON_CALENDAR, Persistent=true)"
    info "next run: $(systemctl show -p NextElapseUSecRealtime --value restic-backup.timer 2>/dev/null)"
fi

# ============================================================== 9. summary
if should_run 9; then
    step 9 'Next steps'
    cat <<EOF

    Review the exclusions, then dry-run before the first real backup:
      \$EDITOR $EXCLUDE_FILE
      $BACKUP_SCRIPT --dry-run
      tail -n 50 /var/log/restic-backup.log

    First real backup (it will take a while):
      $BACKUP_SCRIPT
      tail -f /var/log/restic-backup.log

    Progress of a running backup (systemd hides restic's interactive output):
      sudo kill -USR1 \$(pgrep -x restic)
      tail -f /var/log/restic-backup.log

    Snapshots:
      export RESTIC_REPOSITORY='$REPOSITORY'
      export RESTIC_PASSWORD_FILE='$PASSWORD_FILE'
      restic -o "sftp.command=ssh -F $SSH_CONFIG -o BatchMode=yes $HOST_ALIAS -s sftp" snapshots

    Test the timer end to end:
      sudo systemctl start restic-backup.service
      systemctl status restic-backup.service
      systemctl list-timers restic-backup.timer

EOF
fi

printf '\n'
