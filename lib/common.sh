# shellcheck shell=bash
# Shared helpers: logging, dry-run aware command execution, small utilities.

DRY_RUN=${DRY_RUN:-0}

# How we were run, for hints the user can copy: the bare name when it was
# found on PATH (e.g. swissarmy-usb), otherwise the path they typed (./setup.sh).
PROG=$0
[[ $(command -v "${0##*/}" 2>/dev/null) == "$0" ]] && PROG=${0##*/}

if [[ -t 2 ]]; then
    C_BLUE=$'\033[1;34m' C_YELLOW=$'\033[1;33m' C_RED=$'\033[1;31m'
    C_GREEN=$'\033[1;32m' C_RESET=$'\033[0m'
else
    C_BLUE='' C_YELLOW='' C_RED='' C_GREEN='' C_RESET=''
fi

log()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
ok()   { printf '%s ok%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

is_dry_run() { [[ $DRY_RUN == 1 ]]; }

# run CMD...: execute a command, or only print it in dry-run mode.
run() {
    if is_dry_run; then
        printf '[dry-run]' >&2
        printf ' %q' "$@" >&2
        printf '\n' >&2
    else
        "$@"
    fi
}

# as_root CMD...: like run, but through sudo when not already root.
as_root() {
    if [[ $EUID -eq 0 ]]; then
        run "$@"
    else
        run sudo "$@"
    fi
}

need_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 \
            || die "missing command '$cmd' (run: $PROG deps)"
    done
}

# fetch URL: print a (small) remote file to stdout. Read-only, so it also runs
# in dry-run mode: resolving versions never changes anything.
fetch() {
    curl -fsSL --retry 3 --connect-timeout 20 "$1"
}

# Ask a yes/no question on the terminal. Returns 0 on "y".
confirm() {
    local answer
    [[ -r /dev/tty ]] || die "no terminal available to confirm: $1"
    read -r -p "$1 [y/N] " answer </dev/tty
    [[ $answer == [yY] || $answer == [yY][eE][sS] ]]
}

# One scratch directory per run, removed on exit. Created up front (not lazily)
# so that make_tmp also works inside $(...) subshells.
TMP_ROOT=$(mktemp -d -t swissarmy.XXXXXX)
# shellcheck disable=SC2064  # expand now: the path is fixed
trap "rm -rf '$TMP_ROOT' 2>/dev/null" EXIT

make_tmp() { mktemp -d -p "$TMP_ROOT"; }

# Read KEY from a simple KEY=VALUE file.
kv_get() {
    local file=$1 key=$2
    [[ -f $file ]] || return 0
    sed -n "s/^${key}=//p" "$file" | tail -n 1
}

# trim STRING: strip leading and trailing whitespace.
trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

# copy_hash SRC DEST: copy a (large) file and print its SHA256, reading SRC
# once and never reading DEST back. Shows a progress bar when pv is installed.
copy_hash() {
    local hash
    if command -v pv >/dev/null 2>&1; then
        hash=$(pv -N "copy $(basename "$1")" "$1" | tee "$2" | sha256sum) || return 1
    else
        hash=$(tee "$2" <"$1" | sha256sum) || return 1
    fi
    echo "${hash%% *}"
}

# sha256_progress FILE [LABEL]: print FILE's SHA256, with a progress bar when
# pv is installed (hashing a 6 GB ISO on a USB stick takes minutes).
sha256_progress() {
    if command -v pv >/dev/null 2>&1; then
        pv -N "sha256 ${2:-$(basename "$1")}" "$1" | sha256sum | cut -d' ' -f1
    else
        sha256sum "$1" | cut -d' ' -f1
    fi
}
