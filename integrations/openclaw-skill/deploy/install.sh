#!/bin/sh
# deploy/install.sh - render the POPOPX Mac Node bridge service templates into the operator's own
# user directories, then verify them with the init system instead of assuming they came up.
#
# POSIX sh, no bashisms, `set -eu`, no sudo, no network access at all (nothing is downloaded, so
# nothing is piped into a shell). The only files this script writes are:
#
#   ~/Library/LaunchAgents/com.popopx.bridge.plist          (launchd target)
#   ~/.config/systemd/user/popopx-bridge@<instance>.service (systemd target)
#   <bridge dir>/logs/                                      (owner-only, for the log paths above)
#
# Two refusals come before any write, and both are contract rules rather than preferences:
#
#   1. no PPX_CONSOLE_TOKEN -> stop. The token is the handoff, it is generated per node launch and
#      it is never persisted (integrations/CONTRACT.md §2 · 第 2 节). This script never prints it,
#      never stores it, and never puts it in a rendered unit.
#   2. a unit that would grant the phantom_sentinel lockdown path -> stop. See CONTRACT §7 · 第 7 节:
#      that branch clears the pasteboard, unmounts volumes, sleeps displays and suspends the session
#      with no confirmation and no undo. Deploying it unattended is not this installer's call to make.
#
# Usage:
#   sh deploy/install.sh [bridge-dir] [options]
#
#   bridge-dir            directory holding dist/src/index.js; default: $PWD
#   --target auto|launchd|systemd|both   default auto: launchd on macOS, systemd on Linux
#   --launchd / --systemd                shorthands for --target
#   --instance NAME        systemd unit instance; default "default"
#   --host PATH            absolute path of the host executable that loads the plugin
#                          (default: $PPX_OPENCLAW_BIN, else `command -v openclaw`)
#   --render-only          render and check, but do not touch launchctl or systemctl
#   -h, --help             this text
#
# SPDX-License-Identifier: AGPL-3.0-only

set -eu

LABEL="com.popopx.bridge"
UNIT_BASE="popopx-bridge"
ENTRY_REL="dist/src/index.js"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TEMPLATE_PLIST="${SCRIPT_DIR}/launchd.com.popopx.bridge.plist.template"
TEMPLATE_UNIT="${SCRIPT_DIR}/popopx-bridge@.service.template"

BRIDGE_DIR=""
TARGET="auto"
INSTANCE="default"
HOST_BIN="${PPX_OPENCLAW_BIN:-}"
RENDER_ONLY=0

die() {
    printf 'install: %s\n' "$1" >&2
    exit 1
}

info() {
    printf 'install: %s\n' "$1"
}

usage() {
    sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
}

# `--help` answers before anything is checked: an operator reading the flags has no token yet.
case "${1-}" in
    -h | --help)
        usage
        exit 0
        ;;
esac

# Everything this script writes lives under HOME, in one of the two user directories named above.
if [ -z "${HOME:-}" ]; then
    die "HOME is not set, so there is no user directory to install into. This script never writes outside the user's own LaunchAgents or systemd user directory, and never uses sudo."
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --launchd) TARGET="launchd" ;;
        --systemd) TARGET="systemd" ;;
        --both) TARGET="both" ;;
        --target)
            [ $# -ge 2 ] || die "--target needs auto, launchd, systemd or both"
            TARGET="$2"
            shift
            ;;
        --instance)
            [ $# -ge 2 ] || die "--instance needs a name"
            INSTANCE="$2"
            shift
            ;;
        --host)
            [ $# -ge 2 ] || die "--host needs an absolute path"
            HOST_BIN="$2"
            shift
            ;;
        --render-only) RENDER_ONLY=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*) die "unknown option: $1 (see --help)" ;;
        *)
            [ -z "$BRIDGE_DIR" ] || die "expected one directory argument, got a second: $1"
            BRIDGE_DIR="$1"
            ;;
    esac
    shift
done

# --- 1 · the handoff must exist, and must stay out of every file this script writes --------------

if [ -z "${PPX_CONSOLE_TOKEN:-}" ]; then
    die "PPX_CONSOLE_TOKEN is not set. Start the node, copy the console URL or the token it printed (the menu bar's copy action puts it on the pasteboard), export PPX_CONSOLE_TOKEN in this shell, then run this script again. It is not written to any file and it is never printed here."
fi

case "$TARGET" in
    auto | launchd | systemd | both) ;;
    *) die "--target must be auto, launchd, systemd or both" ;;
esac

if [ "$TARGET" = "auto" ]; then
    case "$(uname -s)" in
        Darwin) TARGET="launchd" ;;
        Linux) TARGET="systemd" ;;
        *) die "no service installer for $(uname -s); pass --launchd or --systemd" ;;
    esac
fi

# --- 2 · the bridge directory and the host executable -------------------------------------------

if [ -z "$BRIDGE_DIR" ]; then
    BRIDGE_DIR="$PWD"
fi
case "$BRIDGE_DIR" in
    /*) ;;
    *) BRIDGE_DIR=$(CDPATH= cd -- "$BRIDGE_DIR" && pwd) ;;
esac
[ -f "${BRIDGE_DIR}/${ENTRY_REL}" ] || die "no ${ENTRY_REL} under ${BRIDGE_DIR}: run npm run build first"
[ -f "$TEMPLATE_PLIST" ] || die "missing template ${TEMPLATE_PLIST}"
[ -f "$TEMPLATE_UNIT" ] || die "missing template ${TEMPLATE_UNIT}"

if [ -z "$HOST_BIN" ]; then
    HOST_BIN=$(command -v openclaw || true)
fi
[ -n "$HOST_BIN" ] || die "no host executable found. Install the OpenClaw-shaped host, pass --host /absolute/path, or set PPX_OPENCLAW_BIN."
case "$HOST_BIN" in
    /*) ;;
    *) die "--host must be an absolute path: launchd and systemd do not search your shell PATH" ;;
esac
[ -x "$HOST_BIN" ] || die "host executable is not runnable: $HOST_BIN"

# --- 3 · the lockdown opt-in is refused, not rendered --------------------------------------------

ALLOW=$(printf '%s' "${PPX_ALLOW_LOCKDOWN:-0}" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
case "$ALLOW" in
    0 | false | no | off) ALLOW="0" ;;
    1 | true | yes | on)
        die "PPX_ALLOW_LOCKDOWN is on, which would make the rendered unit grant the phantom_sentinel lockdown path. Refusing to install it: that action clears the pasteboard, unmounts volumes, sleeps displays and suspends the session with no confirmation, no cooldown and no undo. Read integrations/CONTRACT.md section 7, then opt in by hand - the plugin still demands PPX_BRIDGE_SECRET of at least 16 characters."
        ;;
    *) die "PPX_ALLOW_LOCKDOWN must be 0 or 1, not ${ALLOW}" ;;
esac

umask 077
LOG_DIR="${BRIDGE_DIR}/logs"
[ -d "$LOG_DIR" ] || mkdir -m 700 -p "$LOG_DIR"

# --- 4 · rendering -------------------------------------------------------------------------------

# Escape the characters sed would otherwise read as syntax in a replacement: backslash, & and |.
esc() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

render_plist() {
    sed -e "s|@BRIDGE_DIR@|$(esc "$BRIDGE_DIR")|g" \
        -e "s|@OPENCLAW_BIN@|$(esc "$HOST_BIN")|g" \
        -e "s|@ALLOW_LOCKDOWN@|${ALLOW}|g" \
        "$TEMPLATE_PLIST"
}

render_unit() {
    sed -e "s|\${BRIDGE_DIR}|$(esc "$BRIDGE_DIR")|g" \
        -e "s|\${OPENCLAW_BIN}|$(esc "$HOST_BIN")|g" \
        -e "s|\${ALLOW_LOCKDOWN}|${ALLOW}|g" \
        "$TEMPLATE_UNIT"
}

# Reads the value the rendered unit actually carries for the lockdown path, in either syntax.
rendered_allow() {
    awk '
        /PPX_ALLOW_LOCKDOWN=/ {
            sub(/.*PPX_ALLOW_LOCKDOWN=/, "", $0)
            gsub(/"/, "", $0)
            gsub(/[[:space:]]/, "", $0)
            print
            exit
        }
        /<key>PPX_ALLOW_LOCKDOWN<\/key>/ { want = 1; next }
        want {
            sub(/.*<string>/, "", $0)
            sub(/<\/string>.*/, "", $0)
            gsub(/[[:space:]]/, "", $0)
            print
            exit
        }
    ' "$1"
}

# Fails on a half-rendered file or a template that grants the kill switch regardless of the flag.
check_rendered() {
    file="$1"
    if grep -q -e '@BRIDGE_DIR@' -e '@OPENCLAW_BIN@' -e '@ALLOW_LOCKDOWN@' "$file" \
        || grep -q -F -e '${BRIDGE_DIR}' -e '${OPENCLAW_BIN}' -e '${ALLOW_LOCKDOWN}' "$file"; then
        rm -f "$file"
        die "a placeholder survived rendering; refusing to install a half-rendered unit"
    fi
    value=$(rendered_allow "$file")
    case "$value" in
        "")
            rm -f "$file"
            die "the rendered unit carries no PPX_ALLOW_LOCKDOWN value; the template drifted from install.sh"
            ;;
        0 | false | no | off) ;;
        *)
            rm -f "$file"
            die "refusing to install: the rendered unit would grant the lockdown path (${value})"
            ;;
    esac
}

install_one() {
    kind="$1"
    dest_dir="$2"
    dest="$3"
    tmp="${dest}.tmp.$$"

    [ -d "$dest_dir" ] || mkdir -m 700 -p "$dest_dir"
    case "$kind" in
        launchd) render_plist > "$tmp" ;;
        systemd) render_unit > "$tmp" ;;
    esac
    check_rendered "$tmp"

    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        info "unchanged: ${dest}"
    else
        mv "$tmp" "$dest"
        chmod 600 "$dest"
        info "rendered: ${dest}"
    fi
}

DEST_LAUNCHD="${HOME}/Library/LaunchAgents/${LABEL}.plist"
DEST_SYSTEMD="${HOME}/.config/systemd/user/${UNIT_BASE}@${INSTANCE}.service"

case "$TARGET" in
    launchd) install_one launchd "${HOME}/Library/LaunchAgents" "$DEST_LAUNCHD" ;;
    systemd) install_one systemd "${HOME}/.config/systemd/user" "$DEST_SYSTEMD" ;;
    both)
        install_one launchd "${HOME}/Library/LaunchAgents" "$DEST_LAUNCHD"
        install_one systemd "${HOME}/.config/systemd/user" "$DEST_SYSTEMD"
        ;;
esac

# --- 5 · verification, or the one command the operator has to run -------------------------------

VERIFY=""
LOAD=""

if [ "$RENDER_ONLY" -eq 1 ]; then
    info "render-only: launchd and systemctl were not touched"
else
    case "$TARGET" in
        launchd | both)
            command -v launchctl >/dev/null 2>&1 || die "launchctl is not available on this system"
            DOMAIN="gui/$(id -u)"
            # Re-read rather than reload: a stale agent in the domain would otherwise keep running the
            # previous ProgramArguments, which is exactly how a bad render survives an "successful" install.
            launchctl bootout "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || true
            if ! launchctl bootstrap "$DOMAIN" "$DEST_LAUNCHD"; then
                die "launchctl refused ${DEST_LAUNCHD}. The file was written, so read it, then run: ${VERIFY:-launchctl print ${DOMAIN}/${LABEL}}"
            fi
            launchctl print "${DOMAIN}/${LABEL}" >/dev/null || die "launchctl accepted the file but cannot print ${DOMAIN}/${LABEL}"
            info "launchd has ${DOMAIN}/${LABEL} registered"
            VERIFY="launchctl print ${DOMAIN}/${LABEL}"
            LOAD="launchctl kickstart -k ${DOMAIN}/${LABEL}"
            ;;
    esac
    case "$TARGET" in
        systemd | both)
            command -v systemctl >/dev/null 2>&1 || die "systemctl is not available on this system"
            UNIT="${UNIT_BASE}@${INSTANCE}.service"
            systemctl --user daemon-reload
            systemctl --user enable --now "$UNIT" >/dev/null 2>&1 || systemctl --user restart "$UNIT"
            systemctl --user --no-pager --full status "$UNIT" || die "systemd could not report ${UNIT}"
            VERIFY="systemctl --user status ${UNIT}"
            LOAD="systemctl --user restart ${UNIT}"
            ;;
    esac
fi

printf '\n'
info "next steps, in order:"
info "  1. hand the token to the session (it is not in any file this script wrote, and is not printed here):"
if [ "$TARGET" = "systemd" ]; then
    info "       systemctl --user set-environment PPX_CONSOLE_TOKEN='<token>'   # paste the value the node printed"
else
    info "       launchctl setenv PPX_CONSOLE_TOKEN '<token>'                   # paste the value the node printed"
fi
if [ "$RENDER_ONLY" -eq 1 ]; then
    info "  2. load it and verify, without assuming either succeeded:"
    case "$TARGET" in
        systemd) info "       systemctl --user daemon-reload && systemctl --user enable --now ${UNIT_BASE}@${INSTANCE}.service" ;;
        *) info "       launchctl bootstrap gui/\$(id -u) ${DEST_LAUNCHD}" ;;
    esac
    if [ "$TARGET" = "both" ]; then
        info "       (both templates were rendered; run the pair that matches this OS)"
    fi
fi
if [ -n "$VERIFY" ]; then
    info "  2. verification command, run it and read the output:"
    info "       ${VERIFY}"
    if [ -n "$LOAD" ]; then
        info "  3. restart after a node restart mints a new token: ${LOAD}"
    fi
fi
info "  log: ${LOG_DIR}/bridge.log - one JSON line per event, with the token scrubbed"
info "  refusals to expect in it: refused_lockdownDenied, refused_secretRequired, handoffRejected_tokenRejected"
