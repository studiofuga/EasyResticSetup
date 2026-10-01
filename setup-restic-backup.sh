#!/bin/bash
# =============================================================================
#  setup-restic-backup.sh
#
#  Sets up scheduled restic backups from this Linux machine to a Synology NAS
#  over SFTP. Linux counterpart of Setup-ResticBackup.ps1; same 9 steps, same
#  layout, and it generates the same NAS-side provisioning script.
#
#      1  Check prerequisites (root, restic, ssh, sftp, ssh-keygen, ssh-keyscan)
#      2  Create /etc/restic (root, 700) and install the tools on this machine
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

# Bumped whenever this file changes. It exists so that --update can tell the copy you are
# running from the copy already installed on the machine, and refuse to replace a newer
# one with an older. A hash is compared too, because a version I forgot to bump would
# otherwise hide a real difference.
SCRIPT_VERSION='2026.10.01.1'

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
# Where the machine keeps its own copy of the tools, so one set up from a checkout or a
# USB stick keeps working once that is gone. Mirrors C:\Program Files\restic-backup.
TOOLS_DIR='/usr/local/lib/restic-backup'
BACKUP_PATHS='/home /etc'
KEEP_DAILY=14
KEEP_WEEKLY=8
KEEP_MONTHLY=12
ON_CALENDAR='daily'
# Second chance the same day, for a run that was interrupted or skipped on battery.
RETRY_CALENDAR='*-*-* 19:17'
# Verification. Level 1 (a sample of each new snapshot) runs inside the backup; level
# 2 (1/N of the repository data per run) has its own timer, away from the backup.
# Not command-line options: change them in config.json, then --only 3 and --only 8.
VERIFY_SAMPLE_FILES=8
VERIFY_SAMPLE_MIB=256
VERIFY_SUBSETS=30
VERIFY_CALENDAR='*-*-* 15:00'
# Home Assistant status reporting over MQTT. Off until an HA host is given; an empty
# topic or box is composed at run time (box = NAS user, topic = restic/<box>), so
# only what was chosen on purpose is stored.
HA_HOST=''
HA_PORT=1883
HA_USER=''
HA_TOPIC=''
HA_BOX=''
HA_PASSWORD_FROM=''               # --ha-password-file: read once, stored under $BASE
FROM=1
ONLY=0
SKIP_TIMER=0
NAS_SETUP_ONLY=0
FORCE_EXCLUDES=0
ACCEPT_CHANGES=0
UPDATE=0
FORCE=0

usage() {
    cat <<'USAGE_EOF'
setup-restic-backup.sh - set up scheduled restic backups from this Linux machine to a
Synology NAS over SFTP. Counterpart of Setup-ResticBackup.ps1: same nine steps, same
layout, same config.json, and it generates the same NAS-side provisioning script.

USAGE
  sudo ./setup-restic-backup.sh [--nas-host HOST] [options]   first run
  sudo ./setup-restic-backup.sh --update                      onto a new version
  sudo ./setup-restic-backup.sh --only N                      re-run one step
  ./setup-restic-backup.sh --help

  Needs root. Re-running is safe: every step detects what is already in place and
  skips or repairs it. After the first run no options are needed - they come from
  /etc/restic/config.json.

STEPS
  1  Check prerequisites (root, restic, ssh, sftp, ssh-keygen, ssh-keyscan)
  2  Create /etc/restic (root, 700) and install the tools into
     /usr/local/lib/restic-backup, so a setup run from a checkout or a USB stick
     does not leave the machine depending on it
  3  Write config.json, ssh/config, excludes.txt, restic-backup.sh
  4  Generate the SSH key, the repository password, and the NAS-side script
  5  Trust the NAS host key (the fingerprint is shown for confirmation)
  6  Verify authentication and write access   <-- the one manual gate
  7  Initialise the restic repository
  8  Install and enable restic-backup.service and restic-backup.timer
  9  Print the summary and the first-backup commands

  Step 6 stops until the public key is in the NAS user's authorized_keys. The script
  prints exactly what to run on the NAS, then you re-run it to continue.

WHAT TO PASS ON A FIRST RUN
  --nas-host HOST     NAS hostname or IP. No default and nothing site-specific is
                      baked in, so a first run asks if this is omitted. On a laptop
                      prefer the Tailscale name, so the backup also works away from
                      the LAN.
  --nas-user USER     dedicated Synology account (default: restic-<hostname>)
  --nas-port PORT     SSH port (default 22)
  --repo-path PATH    repository path relative to the SFTP root
                      (default home/restic-repo). "home" singular is DSM's alias for
                      the account's own home and needs no share permission; "homes"
                      plural is the shared folder and needs one a backup-only account
                      normally lacks. This distinction cost an afternoon - do not
                      change it without reason.
  --backup-paths "A B"  what to back up (default: "/home /etc")
  --host-alias NAME   the Host entry written into ssh/config and used in the
                      repository string (default nas-restic)

HOME ASSISTANT (optional, any run)
  After every backup the outcome is published over MQTT, retained, to the broker
  Home Assistant uses. Off until --ha-host is given; stored like everything else.
  --ha-host HOST      MQTT broker address. --ha-host '' turns reporting off
  --ha-port PORT      MQTT port (default 1883)
  --ha-user USER      MQTT account for this machine
  --ha-password-file FILE
                      read the MQTT password from FILE once and store it in
                      /etc/restic/mqtt-password. Without it an interactive run asks,
                      so the password never appears on a command line
  --ha-box NAME       this machine's name in Home Assistant (default: the NAS user)
  --ha-topic TOPIC    state topic (default: restic/<box>)
  Step 3 sends a test message, so "--only 3 --ha-host ..." is enough to switch it on
  for a machine already set up.

OPTIONS
  --from N            start at step N
  --only N            run just step N
  --update            install the tools, regenerate the generated files and
                      re-verify - the same as --from 2, plus a guard that refuses to
                      replace an installed copy with an older one
  --force             let --update install an older version on purpose
  --force-excludes    step 3 leaves an existing excludes.txt alone, because it is
                      meant to be tuned by hand. This replaces it with the current
                      template, keeping the old one as excludes.txt.bak
  --accept-changes    do not ask for confirmation when an option would change this
                      machine's NAS identity
  --skip-timer        do everything except installing the systemd units
  --nas-setup         only write nas-provision-<user>.sh and print how to run it,
                      then exit. Nothing local is changed
  --base DIR          configuration directory (default /etc/restic)
  --tools-dir DIR     tools directory (default /usr/local/lib/restic-backup)
  -h, --help          this text

MOVED TO restic-ctl
  When the backup runs is no longer set here. --on-calendar and --retry-calendar
  were retired: they are properties of a machine that is already set up, and
  changing one should not mean re-running an installer.

    sudo restic-ctl schedule                      show
    sudo restic-ctl schedule '*-*-* 03:30'        change it
    sudo restic-ctl schedule --retry '*-*-* 19:17'

  restic-ctl writes config.json and then calls step 8 here, so the unit still has
  exactly one writer. Passing a retired option says so and exits 2.

AFTERWARDS
  sudo restic-ctl status | snapshots | run | check | schedule
  restic-ctl help

EXIT CODES
  0  done    1  a step failed    2  wrong usage or a missing answer
  3  --update refused: the copy you ran is older than the installed one
USAGE_EOF
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
        --host-alias)   HOST_ALIAS="$2";   GIVEN="$GIVEN host-alias";   shift 2 ;;
        --ha-host)      HA_HOST="$2";      GIVEN="$GIVEN ha-host";      shift 2 ;;
        --ha-port)      HA_PORT="$2";      GIVEN="$GIVEN ha-port";      shift 2 ;;
        --ha-user)      HA_USER="$2";      GIVEN="$GIVEN ha-user";      shift 2 ;;
        --ha-topic)     HA_TOPIC="$2";     GIVEN="$GIVEN ha-topic";     shift 2 ;;
        --ha-box)       HA_BOX="$2";       GIVEN="$GIVEN ha-box";       shift 2 ;;
        --ha-password-file) HA_PASSWORD_FROM="$2"; shift 2 ;;
        # Retired rather than silently ignored: a parameter that is accepted and does
        # nothing is worse than one that is gone. The schedule belongs to restic-ctl.
        --on-calendar)
            echo '--on-calendar is no longer an option of this script.' >&2
            echo "Use:  sudo restic-ctl schedule '$2'" >&2
            echo 'It writes config.json and reinstalls the timer through step 8 here,' >&2
            echo 'so the two can never hold different values.' >&2
            exit 2 ;;
        --retry-calendar)
            echo '--retry-calendar is no longer an option of this script.' >&2
            echo "Use:  sudo restic-ctl schedule --retry '$2'" >&2
            exit 2 ;;
        --from)         FROM="$2"; shift 2 ;;
        --only)         ONLY="$2"; shift 2 ;;
        --skip-timer)   SKIP_TIMER=1; shift ;;
        --nas-setup)    NAS_SETUP_ONLY=1; shift ;;
        --force-excludes) FORCE_EXCLUDES=1; shift ;;
        --accept-changes) ACCEPT_CHANGES=1; shift ;;
        --update)       UPDATE=1; shift ;;
        --force)        FORCE=1; shift ;;
        --base)         BASE="$2"; shift 2 ;;
        --tools-dir)    TOOLS_DIR="$2"; shift 2 ;;
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
    given host-alias || { v="$(cfg nas.hostAlias)";     [ -n "$v" ] && HOST_ALIAS="$v"; }
    given backup-paths || { v="$(cfg backupPaths)";     [ -n "$v" ] && BACKUP_PATHS="$v"; }
    given ha-host  || { v="$(cfg homeAssistant.host)";  [ -n "$v" ] && HA_HOST="$v"; }
    given ha-port  || { v="$(cfg homeAssistant.port)";  [ -n "$v" ] && HA_PORT="$v"; }
    given ha-user  || { v="$(cfg homeAssistant.user)";  [ -n "$v" ] && HA_USER="$v"; }
    given ha-topic || { v="$(cfg homeAssistant.topic)"; [ -n "$v" ] && HA_TOPIC="$v"; }
    given ha-box   || { v="$(cfg homeAssistant.box)";   [ -n "$v" ] && HA_BOX="$v"; }
    # The schedule has no command-line override any more: it is whatever config.json
    # says, and "restic-ctl schedule" is what writes it.
    v="$(cfg schedule.onCalendar)";    [ -n "$v" ] && ON_CALENDAR="$v"
    v="$(cfg schedule.retryCalendar)"; [ -n "$v" ] && RETRY_CALENDAR="$v"

    v="$(cfg retention.daily)";   [ -n "$v" ] && KEEP_DAILY="$v"
    v="$(cfg retention.weekly)";  [ -n "$v" ] && KEEP_WEEKLY="$v"
    v="$(cfg retention.monthly)"; [ -n "$v" ] && KEEP_MONTHLY="$v"

    v="$(cfg verify.sampleFiles)";  [ -n "$v" ] && VERIFY_SAMPLE_FILES="$v"
    v="$(cfg verify.sampleMaxMiB)"; [ -n "$v" ] && VERIFY_SAMPLE_MIB="$v"
    v="$(cfg verify.dataSubsets)";  [ -n "$v" ] && VERIFY_SUBSETS="$v"
    v="$(cfg verify.onCalendar)";   [ -n "$v" ] && VERIFY_CALENDAR="$v"
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
HA_PASSWORD_FILE="$BASE/mqtt-password"
EXCLUDE_FILE="$BASE/excludes.txt"

# Written unquoted into config.json, so a typo here would produce invalid JSON.
case "$HA_PORT" in ''|*[!0-9]*) echo "--ha-port must be a number, got: $HA_PORT" >&2; exit 2 ;; esac
# Also written unquoted. They come from config.json, edited by hand.
for pair in "verify.sampleFiles:$VERIFY_SAMPLE_FILES" "verify.sampleMaxMiB:$VERIFY_SAMPLE_MIB" \
            "verify.dataSubsets:$VERIFY_SUBSETS"; do
    case "${pair#*:}" in
        ''|*[!0-9]*|0) echo "config.json: ${pair%%:*} must be a positive number, got: ${pair#*:}" >&2; exit 2 ;;
    esac
done
if [ -n "$HA_PASSWORD_FROM" ] && [ ! -r "$HA_PASSWORD_FROM" ]; then
    echo "--ha-password-file: cannot read $HA_PASSWORD_FROM" >&2; exit 2
fi
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

    # Each of these files carries ONE machine's public key and names ONE NAS account.
    # Running another machine's authorizes that machine on its own account and does
    # nothing here, while the failure looks identical - which has happened twice. So if
    # a stranger is sitting next to us, say so before printing the instructions.
    others=''
    for f in "$SCRIPT_DIR"/nas-provision-*.sh; do
        [ -f "$f" ] || continue
        [ "$f" = "$NAS_PROVISION" ] && continue
        others="$others $(basename "$f")"
    done
    if [ -n "$others" ]; then
        printf '\n'
        warn "Other machines' provisioning scripts are in this folder:"
        for o in $others; do printf '            %s\n' "$o"; done
        info "Run only $name. Another machine's script authorizes that machine"
        info 'on its own NAS account and changes nothing here, while this step keeps'
        info 'failing with the same "did not accept the key".'
    fi
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
# Reads the version stamp out of another copy of this script. sed rather than running it:
# executing an unknown copy to ask its version is not a trade worth making.
stamped_version() {
    [ -f "$1" ] || return 1
    sed -n "s/^[[:space:]]*SCRIPT_VERSION='\\([^']*\\)'.*/\\1/p" "$1" | head -n 1
}

short_hash() {
    [ -f "$1" ] || return 1
    sha256sum "$1" 2>/dev/null | cut -c1-12
}

# Compares the running copy with the one installed on this machine. Step 2 copies the
# running one over the installed one, so running the installed copy by mistake - the
# obvious thing, since it sits at a known path - would quietly reinstall an older
# version. Echoes one of: none same newer older diverged
compare_installed() {
    _inst="$TOOLS_DIR/setup-restic-backup.sh"
    _run="$SCRIPT_DIR/$(basename "$0")"
    [ "$_run" = "$_inst" ] && { echo same; return; }
    [ -f "$_inst" ] || { echo none; return; }
    _theirs="$(stamped_version "$_inst")"
    [ -n "$_theirs" ] || { echo diverged; return; }
    if [ "$_theirs" = "$SCRIPT_VERSION" ]; then
        if [ "$(short_hash "$_inst")" = "$(short_hash "$_run")" ]; then echo same; else echo diverged; fi
        return
    fi
    # Version sort puts the lower first; if that is the installed one, we are newer.
    _lower="$(printf '%s\n%s\n' "$SCRIPT_VERSION" "$_theirs" | sort -V | head -n 1)"
    if [ "$_lower" = "$_theirs" ]; then echo newer; else echo older; fi
}

assert_not_downgrade() {
    _inst="$TOOLS_DIR/setup-restic-backup.sh"
    _theirs="$(stamped_version "$_inst" 2>/dev/null || true)"
    case "$(compare_installed)" in
        none)  info 'no installed copy yet: this run installs one' ;;
        same)  info "version $SCRIPT_VERSION, same as the installed copy" ;;
        newer) ok "updating the installed copy: $_theirs -> $SCRIPT_VERSION" ;;
        older)
            printf '\n'
            fail "this copy is OLDER than the one installed: $SCRIPT_VERSION vs $_theirs"
            info "running   $SCRIPT_DIR/$(basename "$0")"
            info "installed $_inst"
            printf '\n'
            info 'Continuing would reinstall the older version. Two likely causes: you ran the'
            info 'installed copy instead of the one you just brought over, or the USB copy is'
            info 'stale.'
            printf '\n    %sRun the newer copy instead, or --force to go back on purpose.%s\n\n' \
                "$C_WARN" "$C_OFF"
            [ "$FORCE" = 1 ] || exit 3
            warn 'downgrading anyway (--force)' ;;
        *)
            warn "same version $SCRIPT_VERSION but different content"
            info 'One of the two was edited. Check which one you mean to keep.'
            info "running   $SCRIPT_DIR/$(basename "$0")"
            info "installed $_inst" ;;
    esac
}

# --update is the ordinary way to bring a machine onto a new version of these scripts.
# FROM is only defaulted to 2 when the caller did not choose a step themselves; --from 1
# is indistinguishable from not passing it, and equivalent anyway.
if [ "$UPDATE" = 1 ] && [ "$FROM" = 1 ] && [ "$ONLY" = 0 ]; then
    FROM=2
fi

printf '\n=== restic backup setup ===\n'
info "NAS          $NAS_USER@$NAS_HOST:$NAS_PORT"
info "Repository   $REPOSITORY"
info "Local base   $BASE"
info "Tools        $TOOLS_DIR"
info "Backup paths $BACKUP_PATHS"
if [ -n "$HA_HOST" ]; then
    info "Home Asst.   ${HA_USER:-<no user>}@$HA_HOST:$HA_PORT, box ${HA_BOX:-$NAS_USER}, topic ${HA_TOPIC:-restic/${HA_BOX:-$NAS_USER}}"
else
    info 'Home Asst.   not configured (--ha-host to enable)'
fi

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

if [ "$UPDATE" = 1 ]; then
    step 0 'Update check'
    assert_not_downgrade
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
    step 2 'Directory layout, permissions and tools'
    for d in "$BASE" "$SSH_DIR" "$BASE/cache"; do
        if [ -d "$d" ]; then info "exists $d"; else mkdir -p "$d" && ok "created $d"; fi
    done
    chown -R root:root "$BASE"
    chmod 700 "$BASE" "$SSH_DIR" "$BASE/cache"
    ok 'owned by root, mode 700 (the backup runs as root)'

    # --- the machine gets its own copy of the tools ------------------------------
    # Running the installer from a checkout or a USB stick used to leave everything
    # there, so once it was gone the machine could not be reconfigured or inspected.
    # Executables go on PATH (step 3 installs restic-ctl); the installer and the docs
    # go here. Credentials stay in $BASE, which is root-only: nothing secret is copied.
    [ "$UPDATE" = 1 ] || assert_not_downgrade

    mkdir -p "$TOOLS_DIR"
    chmod 755 "$TOOLS_DIR"
    copied=''
    for name in setup-restic-backup.sh restic-ctl.sh nas-fleet-status.sh \
                RUNBOOK.md README.md Setup-ResticBackup.ps1 restic-ctl.ps1; do
        src="$SCRIPT_DIR/$name"
        [ -f "$src" ] || continue
        # Skip when already running from the destination, which would copy onto itself.
        [ "$src" = "$TOOLS_DIR/$name" ] && continue
        install -m 644 "$src" "$TOOLS_DIR/$name"
        copied="$copied $name"
    done
    for x in setup-restic-backup.sh restic-ctl.sh nas-fleet-status.sh; do
        [ -f "$TOOLS_DIR/$x" ] && chmod 755 "$TOOLS_DIR/$x"
    done
    if [ -n "$copied" ]; then
        ok "installed to $TOOLS_DIR:$copied"
    else
        info 'tools already in place (running from the installed copy)'
    fi
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
    # Through json.dumps rather than interpolated: a topic or an account name is free
    # text, and one stray quote would make the whole file unreadable.
    HA_JSON="$(HA_HOST="$HA_HOST" HA_PORT="$HA_PORT" HA_USER="$HA_USER" \
               HA_TOPIC="$HA_TOPIC" HA_BOX="$HA_BOX" python3 -c '
import json, os
e = os.environ
print(json.dumps({"host": e["HA_HOST"], "port": int(e["HA_PORT"]), "user": e["HA_USER"],
                  "topic": e["HA_TOPIC"], "box": e["HA_BOX"]}))')"
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
  "homeAssistant": $HA_JSON,
  "verify": { "sampleFiles": $VERIFY_SAMPLE_FILES, "sampleMaxMiB": $VERIFY_SAMPLE_MIB,
              "dataSubsets": $VERIFY_SUBSETS, "onCalendar": "$VERIFY_CALENDAR" },
  "paths": { "base": "$BASE", "tools": "$TOOLS_DIR" }
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
#   restic-backup.sh --publish    re-send last-run.json to Home Assistant, no backup
#   restic-backup.sh --publish --dry-run   print the topic and payload, send nothing
#   restic-backup.sh --unpublish  remove this machine from Home Assistant
#   restic-backup.sh --verify-sample [SNAPSHOT]   level 1: dump and hash a sample
#   restic-backup.sh --verify-data   level 2: read the next 1/N of the repository data
#   restic-backup.sh --help       this text
#
# Prefer "restic-ctl run" over calling this by hand: it goes through systemd, so the
# backup runs in the same context the timer uses - same Nice, same IOSchedulingClass,
# same ConditionACPower. A run you start by hand can succeed where the timer's fails.
set -u

BASE='/etc/restic'
CONFIG="$BASE/config.json"
LOG='/var/log/restic-backup.log'
PROGRESS="$BASE/progress.json"
LAST_RUN="$BASE/last-run.json"
HISTORY="$BASE/history.jsonl"

# Before the config check: --help has to work on a machine where something is
# missing, which is exactly when someone reaches for it.
case "${1:-}" in
    -h|--help)
        sed -n '2,17p' "$0" | sed 's/^#//; s/^ //'
        echo
        echo "Reads everything from $CONFIG: paths, retention, the NAS alias."
        echo 'Writes the log, progress.json, last-run.json, history.jsonl, the package'
        echo 'manifest, verify-state.json, and prune-frozen.json when a check fails.'
        echo
        echo 'Generated by setup-restic-backup.sh - edits here are overwritten on the'
        echo 'next --update. Change config.json, or the installer, instead.'
        echo
        echo 'Day to day use restic-ctl, not this script:'
        echo '  sudo restic-ctl run | status | snapshots        restic-ctl help'
        exit 0 ;;
esac

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

# Optional keys: a config.json written before they existed must still work, so a
# missing key reads as empty instead of stopping the backup.
cfg_opt() { cfg "$1" 2>/dev/null || true; }

# Home Assistant reporting. Empty host = off. Box and topic are composed when not set,
# for the same reason as the repository string below.
HA_HOST="$(cfg_opt homeAssistant.host)"
HA_PORT="$(cfg_opt homeAssistant.port)"; HA_PORT="${HA_PORT:-1883}"
HA_USER="$(cfg_opt homeAssistant.user)"
HA_BOX="$(cfg_opt homeAssistant.box)";   HA_BOX="${HA_BOX:-$(cfg_opt nas.user)}"
HA_TOPIC="$(cfg_opt homeAssistant.topic)"; HA_TOPIC="${HA_TOPIC:-restic/$HA_BOX}"
HA_PASSWORD_FILE="$BASE/mqtt-password"

# Verification. Level 1 runs after every backup on a sample of what it uploaded;
# level 2 is the separate restic-verify timer reading 1/N of the repository data a day.
VERIFY_STATE="$BASE/verify-state.json"
# Present while a check has found damage: forget/prune stay off until a human has
# looked ("restic-ctl unfreeze"). Prune rewrites packs, and doing that on a damaged
# repository is how a recoverable problem becomes an unrecoverable one.
FROZEN="$BASE/prune-frozen.json"
VERIFY_SAMPLE_FILES="$(cfg_opt verify.sampleFiles)"; VERIFY_SAMPLE_FILES="${VERIFY_SAMPLE_FILES:-8}"
VERIFY_SAMPLE_MIB="$(cfg_opt verify.sampleMaxMiB)";  VERIFY_SAMPLE_MIB="${VERIFY_SAMPLE_MIB:-256}"
VERIFY_SUBSETS="$(cfg_opt verify.dataSubsets)";      VERIFY_SUBSETS="${VERIFY_SUBSETS:-30}"

# What is installed on this machine, regenerated before every backup and backed up
# with it: a reinstall starts from these lists instead of from memory.
MANIFEST_DIR="$BASE/manifest"

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
    --publish) MODE='publish' ;;
    --unpublish) MODE='unpublish' ;;
    --verify-sample) MODE='verify-sample' ;;
    --verify-data)   MODE='verify-data' ;;
    '')        ;;
    *)         echo "unknown option: $1" >&2; exit 2 ;;
esac
# --verify-sample takes an optional snapshot id; anything else is checked below.
SAMPLE_SNAPSHOT=''
if [ "$MODE" = 'verify-sample' ]; then
    SAMPLE_SNAPSHOT="${2:-latest}"
    set -- "$1"
fi
# --dry-run after --publish or --unpublish previews the messages instead of sending
# them. Checked as a pair so that "--dry-run --publish", which reads like a dry-run
# backup, is refused rather than silently doing one or the other.
PUBLISH_DRY=0
case "${2:-}" in
    '') ;;
    --dry-run) case "$MODE" in publish|unpublish) ;;
                   *) echo "unknown option: $2" >&2; exit 2 ;; esac
               PUBLISH_DRY=1 ;;
    *)  echo "unknown option: $2" >&2; exit 2 ;;
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

# Tells Home Assistant about this machine and its latest outcome over MQTT. Two
# retained messages on one connection, so HA has both again after it restarts:
#
#   homeassistant/device/restic/<id>/config
#       MQTT discovery: the device and its entities. HA creates them the first time
#       it sees this, so a new machine needs nothing on the HA side. "restic" is the
#       optional node id level HA allows there: it keeps every machine of the fleet
#       under one prefix, so a broker ACL can grant exactly homeassistant/device/
#       restic/# and nothing else of HA's discovery space.
#   <topic>, restic/<box> by default
#       the state: last-run.json plus box and publishedAt. Every entity reads its
#       value from here.
#
# Discovery goes first, so HA is already subscribed to the state topic when the
# state arrives. Both are sent on every run: an unchanged discovery message costs HA
# nothing, and resending it brings a device back after someone deleted it in HA.
#
# Plain MQTT 3.1.1 over a socket, in python3 which is already required: no client
# package on every machine, and the password is read from its file here instead of
# passing through a command line where any local user could read it in the process
# list.
#
# Never allowed to change the backup's own result: a broker that is down is logged,
# and the run exits exactly as it would have without it.
#
# Modes:
#   send            the two messages above (the default)
#   dry             build them and print them: the broker is not contacted and
#                   nothing is logged. Works without a broker configured, to preview
#                   what a machine would send before setting one up.
#   unpublish       empty retained messages on both topics: HA removes the device and
#                   its entities, and the broker forgets the state
#   unpublish-dry   print what unpublish would clear
ha_publish() {
    case "${1:-send}" in
        dry|unpublish-dry) ;;
        *) [ -n "$HA_HOST" ] || return 0 ;;
    esac
    python3 - "$HA_HOST" "$HA_PORT" "$HA_USER" "$HA_PASSWORD_FILE" "$HA_TOPIC" \
              "$HA_BOX" "$LAST_RUN" "$LOG" "${1:-send}" "$VERIFY_STATE" "$FROZEN" <<'HA_PY_EOF'
import datetime, json, os, re, socket, struct, sys, time

host, port, user, pwfile, topic, box, last_run, logpath, mode, verify_state, frozen_path \
    = sys.argv[1:12]
dry = mode.endswith("dry")
removing = mode.startswith("unpublish")

# Home Assistant's default discovery prefix. It can only be changed in HA's own MQTT
# settings, and hardly anyone does.
DISCOVERY_PREFIX = "homeassistant"
# Every value the backup can write to "outcome". The Outcome entity is an enum, so
# HA's history shows each one as its own colour band.
OUTCOMES = ["ok", "warnings", "failed", "prune-failed", "never"]
# The verification summary: failed covers a failed or mismatched check and a frozen
# prune; error is a check that could not run; never is a machine not checked yet.
VERIFY_STATUSES = ["ok", "error", "failed", "never"]

def verify_block():
    # The latest of each level, read from verify-state.json, so a backup's publish and
    # a check's publish both send the complete picture and never undo each other.
    try:
        with open(verify_state) as f:
            st = json.load(f)
    except (OSError, ValueError):
        st = {}
    try:
        with open(frozen_path) as f:
            frozen = json.load(f)
    except (OSError, ValueError):
        frozen = None
    sample, data = st.get("sample"), st.get("data")
    outcomes = [x.get("outcome") for x in (sample, data) if isinstance(x, dict)]
    if frozen or any(o in ("failed", "mismatch") for o in outcomes):
        status = "failed"
    elif "error" in outcomes:
        status = "error"
    elif outcomes:
        status = "ok"
    else:
        status = "never"
    return {"status": status, "sample": sample, "data": data,
            "pruneFrozen": bool(frozen),
            "frozenSince": frozen.get("since") if frozen else None,
            "frozenReason": frozen.get("reason") if frozen else None}

def logline(msg):
    with open(logpath, "a") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + "ha: " + msg + "\n")

def s(text):
    b = text.encode("utf-8")
    return struct.pack("!H", len(b)) + b

def packet(kind, body):
    n, rl = len(body), bytearray()
    while True:
        digit, n = n % 128, n // 128
        rl.append(digit | (0x80 if n else 0))
        if not n:
            break
    return bytes([kind]) + bytes(rl) + body

def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("broker closed the connection")
        buf += chunk
    return buf

def read_packet(sock):
    kind = recv_exact(sock, 1)[0]
    length, shift = 0, 0
    while True:
        digit = recv_exact(sock, 1)[0]
        length += (digit & 0x7F) << shift
        if not digit & 0x80:
            break
        shift += 7
    return kind, recv_exact(sock, length)

def machine_id(box):
    # One id for this machine, used as the MQTT client id and as the discovery id:
    # the same string in both places lets a broker ACL grant each machine its own
    # discovery topic with one line, "pattern write homeassistant/device/restic/%c/config".
    # Both allow [A-Za-z0-9_-]. The box usually is the NAS account, restic-<host>, so
    # the prefix is not doubled. 23 characters is the longest client id MQTT 3.1.1
    # obliges a broker to accept.
    cid = re.sub(r"[^A-Za-z0-9_-]", "", box)
    return (cid if cid.startswith("restic") else "restic-" + cid)[:23]

def discovery_config(ident):
    # HA names entities "<device> <entity>": "restic-laptop" + "Last run" becomes
    # sensor.restic_laptop_last_run. A nickname box gets the same "restic" in front,
    # so every machine's entities are sensor.restic_<name>_... and can be found
    # together.
    name = box if box.startswith("restic") else "Restic " + box

    def entity(key, platform, label, field, **extra):
        e = {"platform": platform, "name": label, "unique_id": ident + "_" + key,
             "value_template": field}
        e.update(extra)
        return e

    # "| default(none)": a machine that has never run sends only outcome and host.
    # A missing field then reads as unknown, rather than as a template error in HA's
    # log on every message.
    return {
        "device": {"identifiers": [ident], "name": name,
                   "manufacturer": "EasyResticSetup", "model": "restic backup"},
        "origin": {"name": "EasyResticSetup"},
        # At the root, so it applies to every component below.
        "state_topic": topic,
        "qos": 1,
        "components": {
            "outcome": entity(
                "outcome", "sensor", "Outcome", "{{ value_json.outcome }}",
                device_class="enum", options=OUTCOMES, icon="mdi:backup-restore",
                # The whole record as attributes: snapshot id, file counts, host.
                json_attributes_topic=topic),
            # The end of the last run, successful or not. Paired with a staleness
            # check in HA, it is what catches a machine whose schedule stopped: a
            # retained "ok" would otherwise stay "ok" forever.
            "last_run": entity(
                "last_run", "sensor", "Last run",
                "{{ value_json.finishedAt | default(none) }}",
                device_class="timestamp"),
            "duration": entity(
                "duration", "sensor", "Duration",
                "{{ value_json.durationSec | default(none) }}",
                device_class="duration", unit_of_measurement="s",
                state_class="measurement"),
            "data_added": entity(
                "data_added", "sensor", "Data added",
                "{{ value_json.dataAddedBytes | default(none) }}",
                device_class="data_size", unit_of_measurement="B",
                state_class="measurement"),
            "source_size": entity(
                "source_size", "sensor", "Source size",
                "{{ value_json.bytesProcessed | default(none) }}",
                device_class="data_size", unit_of_measurement="B",
                state_class="measurement"),
            # On for anything but "ok": warnings, failures, a failed prune, and a
            # machine that has never backed up.
            "problem": entity(
                "problem", "binary_sensor", "Problem",
                "{{ 'OFF' if value_json.outcome == 'ok' else 'ON' }}",
                device_class="problem"),
            # Verification. "| default({})" at each level: a state message from a
            # version without the verify block must read as never/unknown, not as a
            # template error.
            "verification": entity(
                "verification", "sensor", "Verification",
                "{{ (value_json.verify | default({})).status | default('never') }}",
                device_class="enum", options=VERIFY_STATUSES, icon="mdi:shield-check"),
            "last_data_check": entity(
                "last_data_check", "sensor", "Last data check",
                "{{ ((value_json.verify | default({})).data | default({})).at | default(none) }}",
                device_class="timestamp"),
            # When the rotating data check last finished a full pass over the
            # repository: every pack downloaded and verified at least once since.
            "coverage_completed": entity(
                "coverage_completed", "sensor", "Data fully verified",
                "{{ ((value_json.verify | default({})).data | default({})).cycleCompletedAt"
                " | default(none) }}",
                device_class="timestamp"),
            # On when a check found damage (and the prune is frozen) or could not
            # run. Off for "never", so a machine just updated does not raise an alarm
            # before its first check has had a chance to run.
            "verification_problem": entity(
                "verification_problem", "binary_sensor", "Verification problem",
                "{{ 'ON' if (value_json.verify | default({})).status | default('never')"
                " in ['failed', 'error'] else 'OFF' }}",
                device_class="problem"),
        },
    }

try:
    if not topic or "+" in topic or "#" in topic:
        raise ValueError("invalid topic %r" % topic)
    ident = machine_id(box)
    config_topic = "%s/device/restic/%s/config" % (DISCOVERY_PREFIX, ident)

    if removing:
        # Empty and retained: that is how MQTT deletes a retained message, and how
        # HA is told a discovered device is gone.
        messages = [(config_topic, b""), (topic, b"")]
    else:
        try:
            with open(last_run) as f:
                record = json.load(f)
        except (OSError, ValueError):
            # Nothing has run yet. Said explicitly rather than sending nothing, so HA
            # can tell a machine that never backed up from one that is not reporting.
            record = {"outcome": "never", "host": socket.gethostname()}
        record["box"] = box
        record["verify"] = verify_block()
        record["publishedAt"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
        discovery = discovery_config(ident)
        messages = [(config_topic, json.dumps(discovery).encode("utf-8")),
                    (topic, json.dumps(record).encode("utf-8"))]

    password = ""
    if os.path.exists(pwfile):
        with open(pwfile) as f:
            password = f.read().strip()

    client_id = ident
    flags = 0x02                                   # clean session
    tail = s(client_id)
    if user:
        flags |= 0x80
        tail += s(user)
        if password:                               # 3.1.1: no password without a user
            flags |= 0x40
            tail += s(password)

    if dry:
        if host:
            broker = "%s@%s:%s" % (user or "<no user>", host, port)
            auth = ("password stored" if password else "no password") if user else "anonymous"
        else:
            broker, auth = "not configured - nothing would be sent", "-"
        print("Broker     %s" % broker)
        print("Login      %s" % auth)
        print("Client id  %s" % client_id)
        print("Delivery   QoS 1, retained")
        if removing:
            print("Discovery  %s, emptied" % config_topic)
            print("Topic      %s, emptied" % topic)
        else:
            print("Discovery  %s, %d bytes" % (config_topic, len(messages[0][1])))
            print("Topic      %s, %d bytes" % (topic, len(messages[1][1])))
            print("")
            print("Discovery payload:")
            print(json.dumps(discovery, indent=2))
            print("")
            print("State payload:")
            print(json.dumps(record, indent=2))
        sys.exit(0)

    sock = socket.create_connection((host, int(port)), timeout=15)
    try:
        sock.sendall(packet(0x10, s("MQTT") + bytes([4, flags]) + struct.pack("!H", 30) + tail))
        kind, body = read_packet(sock)
        if kind != 0x20 or len(body) != 2:
            raise ConnectionError("unexpected reply to CONNECT (0x%02x)" % kind)
        if body[1] != 0:
            reasons = {1: "protocol version refused", 2: "client id refused",
                       3: "server unavailable", 4: "bad user name or password",
                       5: "not authorized"}
            raise PermissionError(reasons.get(body[1], "refused, code %d" % body[1]))

        # QoS 1 + retain: the broker confirms it has each message, and keeps it.
        # One at a time, each waiting for its PUBACK, so the order holds.
        for pid, (t, payload) in enumerate(messages, 1):
            sock.sendall(packet(0x33, s(t) + struct.pack("!H", pid) + payload))
            while True:
                kind, body = read_packet(sock)
                if kind & 0xF0 == 0x40 and body[:2] == struct.pack("!H", pid):
                    break
        sock.sendall(bytes([0xE0, 0]))
    finally:
        sock.close()
    if removing:
        logline("unpublished %s and %s on %s:%s" % (config_topic, topic, host, port))
        print("removed from Home Assistant: %s and %s cleared on %s:%s"
              % (config_topic, topic, host, port))
    else:
        logline("published %s to %s on %s:%s, discovery %s"
                % (record.get("outcome"), topic, host, port, config_topic))
        print("published to %s on %s:%s, discovery %s" % (topic, host, port, config_topic))
except Exception as e:
    if dry:
        print("cannot build the message: %s" % e, file=sys.stderr)
        sys.exit(1)
    what = "unpublish" if removing else "publish"
    logline("%s FAILED: %s" % (what, e))
    print("%s failed: %s" % (what, e), file=sys.stderr)
    sys.exit(1)
HA_PY_EOF
}

# =============================================================================
#  Package manifest
#
#  What is installed, written before every backup into $MANIFEST_DIR and backed up
#  with everything else, so a reinstall has a list to work from. Best effort: a
#  manager that is missing is skipped, one that fails is logged, and the backup runs
#  either way. Written to a temporary directory and swapped in, so a half-written
#  manifest never replaces a complete one.
# =============================================================================
write_manifest() {
    tmp="$MANIFEST_DIR.new"
    rm -rf "$tmp" && mkdir -p "$tmp" && chmod 700 "$tmp" || { log 'manifest: cannot create its directory'; return 0; }

    if command -v apt-mark >/dev/null 2>&1; then
        # Manually installed: what to hand to apt on a new system. Everything else
        # comes back as a dependency.
        apt-mark showmanual > "$tmp/apt-manual.txt" 2>>"$LOG" || log 'manifest: apt-mark failed'
    fi
    if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' \
            > "$tmp/dpkg-all.tsv" 2>>"$LOG" || log 'manifest: dpkg-query failed'
    fi
    if command -v flatpak >/dev/null 2>&1; then
        flatpak list --app --system --columns=application,origin,branch \
            > "$tmp/flatpak-system.tsv" 2>>"$LOG" || log 'manifest: flatpak (system) failed'
        # Per-user installations live in each home and are backed up as data; the
        # list says what to reinstall. Only for users that actually have one.
        for d in /home/*/.local/share/flatpak; do
            [ -d "$d" ] || continue
            u="$(stat -c %U "${d%/.local/share/flatpak}")"
            runuser -u "$u" -- flatpak list --app --user --columns=application,origin,branch \
                > "$tmp/flatpak-user-$u.tsv" 2>>"$LOG" || log "manifest: flatpak (user $u) failed"
        done
    fi
    if command -v snap >/dev/null 2>&1; then
        snap list > "$tmp/snap.txt" 2>/dev/null || true
    fi

    cat > "$tmp/README.txt" <<'MANIFEST_README_EOF'
What was installed on this machine at the time of the snapshot this folder came from.
Generated by restic-backup.sh before every backup.

  apt-manual.txt        packages installed by hand: the list to reinstall
                        sudo apt-get install $(cat apt-manual.txt)
                        Restore /etc/apt (sources and keyrings) first, or packages
                        from third-party repositories will not be found.
  dpkg-all.tsv          every package with its version and state, for reference
  flatpak-system.tsv    system-wide flatpak apps:
                        flatpak install --system <origin> <application>
  flatpak-user-*.tsv    per-user flatpak apps; their data is in the home backup
  snap.txt              snaps

Not covered: pip/npm/cargo installs, AppImages, anything under /opt or /usr/local
that no package manager knows about.
MANIFEST_README_EOF

    rm -rf "$MANIFEST_DIR.old"
    [ -d "$MANIFEST_DIR" ] && mv "$MANIFEST_DIR" "$MANIFEST_DIR.old"
    mv "$tmp" "$MANIFEST_DIR" && rm -rf "$MANIFEST_DIR.old"
    log "manifest: $(ls "$MANIFEST_DIR" | tr '\n' ' ')"
}

# The manifest has to be inside the backup. It is under /etc, so it already is when
# /etc is backed up; otherwise its directory is added to this run's paths.
manifest_backup_paths() {
    for p in $BACKUP_PATHS; do
        case "$MANIFEST_DIR/" in "${p%/}/"*) printf '%s' "$BACKUP_PATHS"; return ;; esac
    done
    printf '%s %s' "$BACKUP_PATHS" "$MANIFEST_DIR"
}

# =============================================================================
#  Verification, level 1: a sample of the snapshot just written
#
#  Picks up to VERIFY_SAMPLE_FILES files the snapshot added or changed - the data
#  this run actually uploaded - within VERIFY_SAMPLE_MIB, and reads each one back
#  with "restic dump", hashing the stream: nothing is written to disk. restic checks
#  every blob as it decrypts it, so a dump that completes is intact data. When the
#  live file has not changed since the snapshot started, its hash is compared too,
#  which also catches "backed up the wrong thing".
#
#  Outcomes: ok; skipped (nothing suitable to sample); failed (a dump failed twice);
#  mismatch (a dump differs from an unchanged original); error (the sample could not
#  be put together - a tool problem, not evidence of damage). failed and mismatch
#  freeze the prune.
#
#  Exit: 0 ok or skipped, 1 failed or mismatch, 2 error.
# =============================================================================
verify_sample() {
    python3 - "$1" "$VERIFY_SAMPLE_FILES" "$VERIFY_SAMPLE_MIB" "$SFTP_COMMAND" \
              "$LOG" "$VERIFY_STATE" "$FROZEN" <<'VERIFY_SAMPLE_PY_EOF'
import datetime, hashlib, json, os, random, re, subprocess, sys, tempfile, time

snap, nfiles, maxmib, sftp, logpath, state_path, frozen_path = sys.argv[1:8]
nfiles, budget = int(nfiles), int(maxmib) * 1024 * 1024

def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")

def logline(msg):
    with open(logpath, "a") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + "verify-sample: " + msg + "\n")

def restic(*args):
    return ["restic", "-o", "sftp.command=" + sftp] + list(args)

def parse_time(t):
    # restic writes nanoseconds; Python before 3.11 takes at most microseconds.
    t = re.sub(r"(\.\d{6})\d+", r"\1", t).replace("Z", "+00:00")
    return datetime.datetime.fromisoformat(t).timestamp()

def save(result):
    try:
        with open(state_path) as f:
            state = json.load(f)
    except (OSError, ValueError):
        state = {}
    state["sample"] = result
    tmp = state_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2)
    os.replace(tmp, state_path)

def freeze(reason):
    if os.path.exists(frozen_path):
        return
    tmp = frozen_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"since": now_iso(), "by": "verify-sample", "reason": reason}, f, indent=2)
    os.replace(tmp, frozen_path)
    logline("PRUNE FROZEN: " + reason)

def dump_hash(path):
    # stderr to a file, not a pipe: a pipe nobody reads can fill and stall restic.
    last = ""
    for _ in range(2):
        with tempfile.TemporaryFile() as err:
            p = subprocess.Popen(restic("dump", snap_id, path), stdout=subprocess.PIPE, stderr=err)
            h, n = hashlib.sha256(), 0
            for chunk in iter(lambda: p.stdout.read(1 << 20), b""):
                h.update(chunk)
                n += len(chunk)
            rc = p.wait()
            if rc == 0:
                return h.hexdigest(), n, None
            err.seek(0)
            lines = err.read().decode("utf-8", "replace").strip().splitlines()
            last = lines[-1] if lines else "exit %d" % rc
    return None, n, last

def live_hash(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

started = time.time()
result = {"at": now_iso(), "snapshotId": snap, "outcome": None, "files": 0,
          "compared": 0, "bytes": 0, "durationSec": 0, "problems": []}
code = 0
try:
    out = subprocess.run(restic("snapshots", "--json", snap), capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError("restic snapshots %s: %s" % (snap, out.stderr.strip()[-300:]))
    meta = json.loads(out.stdout)
    if not meta:
        raise RuntimeError("no snapshot %s" % snap)
    meta = meta[-1]
    snap_id = meta["id"]
    result["snapshotId"] = meta.get("short_id", snap_id[:8])
    snap_time = parse_time(meta["time"])

    # Candidates: what this snapshot added or changed relative to its parent. Old
    # data is the rotating data check's job; this one is about what was just sent.
    candidates, source = [], "changed"
    parent = meta.get("parent")
    if parent:
        d = subprocess.run(restic("diff", "--json", parent, snap_id),
                           capture_output=True, text=True)
        if d.returncode != 0:
            raise RuntimeError("restic diff: %s" % d.stderr.strip()[-300:])
        for line in d.stdout.splitlines():
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if o.get("message_type") != "change":
                continue
            mod, path = o.get("modifier", ""), o.get("path", "")
            if ("+" in mod or "M" in mod) and path and not path.endswith("/"):
                candidates.append(path)
    if not candidates:
        # First snapshot, or nothing changed: a random sample of the whole snapshot.
        source = "random"
        ls = subprocess.Popen(restic("ls", "--json", snap_id), stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, text=True)
        seen, keep = 0, max(nfiles * 50, 200)
        for line in ls.stdout:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if o.get("type") != "file" or "path" not in o:
                continue
            seen += 1
            if len(candidates) < keep:
                candidates.append(o["path"])
            else:
                j = random.randrange(seen)
                if j < keep:
                    candidates[j] = o["path"]
        if ls.wait() != 0:
            raise RuntimeError("restic ls failed")
    result["source"] = source

    # Only files that still exist: their size bounds the download before it starts.
    random.shuffle(candidates)
    picked, room = [], budget
    for path in candidates[:5000]:
        if len(picked) >= nfiles:
            break
        try:
            st = os.stat(path)
        except OSError:
            continue
        if not os.path.isfile(path) or st.st_size > room:
            continue
        picked.append(path)
        room -= st.st_size

    if not picked:
        result["outcome"] = "skipped"
        logline("nothing suitable to sample in %s (%d candidates)" % (result["snapshotId"], len(candidates)))
    else:
        for path in picked:
            digest, n, err = dump_hash(path)
            result["files"] += 1
            result["bytes"] += n
            if digest is None:
                result["problems"].append({"path": path, "problem": "dump failed: " + err})
                continue
            try:
                st = os.stat(path)
                if st.st_mtime < snap_time and st.st_size == n:
                    live = live_hash(path)
                    if os.stat(path).st_mtime == st.st_mtime:
                        result["compared"] += 1
                        if live != digest:
                            result["problems"].append(
                                {"path": path, "problem": "differs from the unchanged original"})
            except OSError:
                pass
        kinds = [p["problem"] for p in result["problems"]]
        if any(k.startswith("dump failed") for k in kinds):
            result["outcome"], code = "failed", 1
        elif kinds:
            result["outcome"], code = "mismatch", 1
        else:
            result["outcome"] = "ok"
except Exception as e:
    result["outcome"], code = "error", 2
    result["problems"].append({"path": None, "problem": str(e)[:300]})

result["durationSec"] = int(time.time() - started)
result["problems"] = result["problems"][:5]
save(result)
logline("%s: %s, %d files (%d compared with the original), %.1f MiB, %ds"
        % (result["snapshotId"], result["outcome"], result["files"], result["compared"],
           result["bytes"] / 1048576, result["durationSec"]))
for p in result["problems"]:
    logline("  %s: %s" % (p["path"], p["problem"]))
if result["outcome"] in ("failed", "mismatch"):
    freeze("sample check of %s: %s" % (result["snapshotId"], result["problems"][0]["problem"]))
print("%s: %d files, %d compared, %.1f MiB" % (result["outcome"], result["files"],
                                               result["compared"], result["bytes"] / 1048576))
sys.exit(code)
VERIFY_SAMPLE_PY_EOF
}

# =============================================================================
#  Verification, level 2: the next 1/N of the repository data
#
#  "restic check --read-data-subset=n/N", with n kept in verify-state.json and
#  advanced only after a successful run, so after N good runs every pack has been
#  downloaded and verified once - and a day missed delays the cycle instead of
#  leaving a gap. Run by restic-verify.timer, not by the backup.
#
#  Outcomes: ok; failed (restic found damage: the prune is frozen); error (the check
#  could not run - lock held, NAS unreachable: no evidence about the data); skipped
#  (a backup was running).
#
#  Exit: 0 ok or skipped, 1 failed, 2 error.
# =============================================================================
verify_data() {
    if systemctl is-active --quiet restic-backup.service 2>/dev/null; then
        log 'verify-data: skipped, a backup is running; the subset is tried again next time'
        echo 'skipped: a backup is running'
        return 0
    fi
    python3 - "$VERIFY_SUBSETS" "$SFTP_COMMAND" "$LOG" "$VERIFY_STATE" "$FROZEN" \
        <<'VERIFY_DATA_PY_EOF'
import datetime, json, os, re, subprocess, sys, time

subsets, sftp, logpath, state_path, frozen_path = sys.argv[1:6]
subsets = int(subsets)

def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")

def logline(msg):
    with open(logpath, "a") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + "verify-data: " + msg + "\n")

try:
    with open(state_path) as f:
        state = json.load(f)
except (OSError, ValueError):
    state = {}
cursor = state.get("dataCursor") or {}
# A changed N restarts the cycle: subset n of 30 and subset n of 12 are not the same
# slice of the repository.
if cursor.get("subsets") != subsets or not 1 <= int(cursor.get("next", 1)) <= subsets:
    cursor = {"subsets": subsets, "next": 1, "cycleStartedAt": now_iso(),
              "cycleCompletedAt": cursor.get("cycleCompletedAt")}
n = int(cursor["next"])
subset = "%d/%d" % (n, subsets)

started = time.time()
logline("restic check --read-data-subset=%s" % subset)
p = subprocess.run(["restic", "-o", "sftp.command=" + sftp, "check",
                    "--read-data-subset=" + subset], capture_output=True, text=True)
output = (p.stdout + p.stderr).strip()
with open(logpath, "a") as f:
    f.write(output + "\n")

if p.returncode == 0:
    outcome = "ok"
    cursor["next"] = n + 1
    if n >= subsets:
        cursor["next"] = 1
        cursor["cycleCompletedAt"] = now_iso()
        cursor["cycleStartedAt"] = now_iso()
else:
    # A check that could not run says nothing about the data. Only these are treated
    # that way; anything else restic reports is taken as damage.
    not_run = re.search(r"repository is already locked|unable to create lock|"
                        r"Fatal: unable to open|connection (refused|reset|lost)|"
                        r"no route to host|timed out|ssh: ", output, re.I)
    outcome = "error" if not_run else "failed"

problem = None
if outcome != "ok":
    lines = [l for l in output.splitlines() if l.strip()]
    problem = (lines[-1] if lines else "exit %d" % p.returncode)[:300]

state["dataCursor"] = cursor
state["data"] = {"at": now_iso(), "outcome": outcome, "subset": subset,
                 "exitCode": p.returncode, "durationSec": int(time.time() - started),
                 "cycleCompletedAt": cursor.get("cycleCompletedAt"), "problem": problem}
tmp = state_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(state, f, indent=2)
os.replace(tmp, state_path)
logline("%s: %s in %ds%s" % (subset, outcome, state["data"]["durationSec"],
                             ", " + problem if problem else ""))

if outcome == "failed" and not os.path.exists(frozen_path):
    with open(frozen_path + ".tmp", "w") as f:
        json.dump({"since": now_iso(), "by": "verify-data",
                   "reason": "data check %s: %s" % (subset, problem)}, f, indent=2)
    os.replace(frozen_path + ".tmp", frozen_path)
    logline("PRUNE FROZEN: data check %s found damage" % subset)

print("%s: subset %s%s" % (outcome, subset, " - " + problem if problem else ""))
sys.exit({"ok": 0, "failed": 1, "error": 2}[outcome])
VERIFY_DATA_PY_EOF
}

if [ "$MODE" = 'publish' ] || [ "$MODE" = 'unpublish' ]; then
    if [ "$PUBLISH_DRY" = 1 ]; then
        if [ "$MODE" = 'publish' ]; then ha_publish dry; else ha_publish unpublish-dry; fi
        exit $?
    fi
    if [ -z "$HA_HOST" ]; then
        echo "Home Assistant is not configured (no homeAssistant.host in $CONFIG)." >&2
        exit 2
    fi
    if [ "$MODE" = 'publish' ]; then ha_publish; else ha_publish unpublish; fi
    exit $?
fi

if [ "$MODE" = 'verify-sample' ] || [ "$MODE" = 'verify-data' ]; then
    log "===== $MODE ====="
    if [ "$MODE" = 'verify-sample' ]; then verify_sample "$SAMPLE_SNAPSHOT"; else verify_data; fi
    rc=$?
    ha_publish >/dev/null 2>&1 || true
    exit $rc
fi

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

write_manifest
RUN_PATHS="$(manifest_backup_paths)"

rm -f "$PROGRESS.summary"
set -o pipefail
# shellcheck disable=SC2086
if [ "$MODE" = 'dryrun' ]; then
    restic -o "sftp.command=$SFTP_COMMAND" backup --json --dry-run --exclude-caches \
        --exclude-file "$EXCLUDE_FILE" --tag scheduled $RUN_PATHS 2>&1 | filter_json_progress
else
    restic -o "sftp.command=$SFTP_COMMAND" backup --json --exclude-caches \
        --exclude-file "$EXCLUDE_FILE" --tag scheduled $RUN_PATHS 2>&1 | filter_json_progress
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

if [ "$outcome" = 'failed' ]; then
    [ "$MODE" = 'dryrun' ] || ha_publish >/dev/null 2>&1 || true
    exit "$rc"
fi

# Level 1: read back a sample of what this run uploaded, before anything is pruned.
# Its own result goes to verify-state.json; it never changes the backup's outcome or
# exit code - but if it finds damage it freezes the prune just below.
if [ "$MODE" != 'dryrun' ]; then
    snap_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("snapshotId") or "")' \
               "$LAST_RUN" 2>/dev/null)"
    if [ -n "$snap_id" ]; then
        verify_sample "$snap_id" >/dev/null 2>&1 || true
    else
        log 'verify-sample: no snapshot id from this run, skipped'
    fi
fi

if [ "$MODE" != 'dryrun' ] && [ -f "$FROZEN" ]; then
    log "forget/prune SKIPPED: frozen since a check found damage ($FROZEN)"
    log 'Investigate, then: sudo restic-ctl unfreeze'
    ha_publish >/dev/null 2>&1 || true
    log '===== backup finished (prune frozen) ====='
    exit 0
fi

if [ "$MODE" != 'dryrun' ]; then
    run_restic forget --prune \
        --keep-daily "$KEEP_DAILY" \
        --keep-weekly "$KEEP_WEEKLY" \
        --keep-monthly "$KEEP_MONTHLY"
    prc=$?
    if [ "$prc" -ne 0 ]; then
        log "forget/prune FAILED (exit $prc)"
        # Same record, outcome corrected: the snapshot exists, but the repository was
        # not cleaned up, and repeated failures here mean it grows without limit.
        # Matches what the Windows script records.
        record="$(PRC="$prc" python3 -c '
import json, os, sys
r = json.load(open(sys.argv[1]))
r["outcome"] = "prune-failed"
r["pruneExitCode"] = int(os.environ["PRC"])
print(json.dumps(r, indent=2))' "$LAST_RUN" 2>/dev/null)"
        [ -n "$record" ] && write_json "$LAST_RUN" "$record"
        ha_publish >/dev/null 2>&1 || true
        exit "$prc"
    fi
    ha_publish >/dev/null 2>&1 || true
fi

log '===== backup finished ====='
exit 0
BACKUP_SCRIPT_EOF
    chmod 700 "$BACKUP_SCRIPT"
    ok "$BACKUP_SCRIPT"

    # restic-ctl needs no configuration of its own - it reads config.json - so it is
    # simply put on PATH when it is shipped alongside this installer.
    # 755, not 700: the script holds no secrets - it is the same file that sits in version
    # control - and what actually gates it is the credentials, which are root-only in
    # $BASE. Leaving it readable lets a non-root caller reach the script's own "run me with
    # sudo" message instead of a bare Permission denied from the shell.
    if [ -f "$SCRIPT_DIR/restic-ctl.sh" ]; then
        install -m 755 "$SCRIPT_DIR/restic-ctl.sh" /usr/local/bin/restic-ctl
        ok '/usr/local/bin/restic-ctl'
    else
        info 'restic-ctl.sh not found next to this script, skipping its install'
    fi

    # --- Home Assistant: the MQTT password and a test message ---------------------
    # The password gets its own root-only file, like the repository password, rather
    # than a field in config.json: config.json is shown by "restic-ctl config" and is
    # the file people copy around when comparing machines.
    if [ -z "$HA_HOST" ]; then
        info 'Home Assistant reporting off (--ha-host to enable)'
    else
        if [ -n "$HA_PASSWORD_FROM" ]; then
            ( umask 077; tr -d '\r\n' < "$HA_PASSWORD_FROM" > "$HA_PASSWORD_FILE" ) \
                || die "cannot write $HA_PASSWORD_FILE"
            ok "MQTT password stored in $HA_PASSWORD_FILE"
        elif [ -f "$HA_PASSWORD_FILE" ]; then
            info 'MQTT password already present, kept (--ha-password-file to replace)'
        elif [ -n "$HA_USER" ] && [ -t 0 ]; then
            printf '    MQTT password for %s (input hidden, empty for none): ' "$HA_USER"
            read -rs ha_pw; printf '\n'
            if [ -n "$ha_pw" ]; then
                ( umask 077; printf '%s' "$ha_pw" > "$HA_PASSWORD_FILE" ) \
                    || die "cannot write $HA_PASSWORD_FILE"
                ok "MQTT password stored in $HA_PASSWORD_FILE"
            fi
            unset ha_pw
        elif [ -n "$HA_USER" ]; then
            warn "no MQTT password stored and no terminal to ask: pass --ha-password-file"
        fi
        [ -f "$HA_PASSWORD_FILE" ] && chmod 600 "$HA_PASSWORD_FILE"

        # Sent now rather than discovered wrong at 3 a.m.: a bad password or an
        # unreachable broker shows here, while someone is looking. It republishes the
        # last run, or "never" on a new machine - both true statements.
        if out="$("$BACKUP_SCRIPT" --publish 2>&1)"; then
            ok "Home Assistant: $out"
        else
            warn "Home Assistant: $out"
            info 'The backup itself is not affected; it only stops reporting. Fix it'
            info 'and re-run with --only 3, or test with: sudo restic-backup.sh --publish'
        fi
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

    # Level 2 verification: 1/N of the repository data per run, through the same
    # script so it shares the configuration, the log and the Home Assistant report.
    # Its own unit and timer, so a long check never delays a backup or its prune, and
    # the same conditions as the backup: mains power, idle sleep held off.
    if [ -n "$INHIBIT" ]; then
        VERIFY_EXEC="$INHIBIT --what=idle --why=restic-verify --mode=block $BACKUP_SCRIPT --verify-data"
    else
        VERIFY_EXEC="$BACKUP_SCRIPT --verify-data"
    fi
    cat > /etc/systemd/system/restic-verify.service <<EOF
[Unit]
Description=restic: verify the next slice of the repository data
Documentation=file://$CONFIG
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$VERIFY_EXEC
Nice=10
IOSchedulingClass=idle
ConditionACPower=true
# Exit 1 is damage found, 2 a check that could not run: both should show as failed
# in "systemctl status", so no SuccessExitStatus here.
EOF

    cat > /etc/systemd/system/restic-verify.timer <<EOF
[Unit]
Description=Run the restic data verification on a schedule

[Timer]
OnCalendar=$VERIFY_CALENDAR
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now restic-backup.timer >/dev/null 2>&1
    ok "restic-backup.timer enabled (OnCalendar=$ON_CALENDAR, Persistent=true)"
    systemctl enable --now restic-verify.timer >/dev/null 2>&1
    ok "restic-verify.timer enabled (OnCalendar=$VERIFY_CALENDAR, 1/$VERIFY_SUBSETS of the data per run)"

    # Step 8 owns the timer, config.json owns the intent. Without this, running
    # "--only 8 --on-calendar ..." changed the timer while config.json still held the old
    # value, and the next "--from 3" would quietly put it back.
    if [ -f "$CONFIG" ]; then
        ON_CALENDAR="$ON_CALENDAR" RETRY_CALENDAR="$RETRY_CALENDAR" \
        python3 -c '
import json, os, sys
p = sys.argv[1]
with open(p) as f:
    d = json.load(f)
s = d.setdefault("schedule", {})
before = dict(s)
s["onCalendar"] = os.environ["ON_CALENDAR"]
s["retryCalendar"] = os.environ["RETRY_CALENDAR"]
if s != before:
    tmp = p + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    os.replace(tmp, p)
    print("updated")
' "$CONFIG" 2>/dev/null | grep -q updated \
            && ok "config.json updated: OnCalendar=$ON_CALENDAR, retry=$RETRY_CALENDAR"
    fi
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
