#!/usr/bin/env bash
# swissarmy-usb: build a multiboot USB stick with Ventoy.
# Run ./setup.sh --help for usage.
set -euo pipefail

# Resolve symlinks, so a link to setup.sh (e.g. ~/.local/bin/swissarmy-usb) works.
REPO_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")

# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"
# shellcheck source=lib/device.sh
source "$REPO_DIR/lib/device.sh"
# shellcheck source=lib/ventoy.sh
source "$REPO_DIR/lib/ventoy.sh"
# shellcheck source=lib/themes.sh
source "$REPO_DIR/lib/themes.sh"
# shellcheck source=lib/manifest.sh
source "$REPO_DIR/lib/manifest.sh"
# shellcheck source=lib/resolvers.sh
source "$REPO_DIR/lib/resolvers.sh"
# shellcheck source=lib/isos.sh
source "$REPO_DIR/lib/isos.sh"
# shellcheck source=lib/config.sh
source "$REPO_DIR/lib/config.sh"
# shellcheck source=lib/persistence.sh
source "$REPO_DIR/lib/persistence.sh"
# shellcheck source=lib/link.sh
source "$REPO_DIR/lib/link.sh"
# shellcheck source=lib/cli.sh
source "$REPO_DIR/lib/cli.sh"

STICK_LABEL=SWISSARMY
SIZE=4096
UEFI=0
WITH_QEMU=0
AUTO_CONFIG=1

# The version is in VERSION, at the top of the repository.
version() { echo "swissarmy-usb $(<"$REPO_DIR/VERSION")"; }

usage() {
    echo "Usage: $PROG [--dry-run] <command> [args] [options]"
    echo
    echo "Commands:"
    cli_help_commands
    echo
    echo "Options:"
    cli_help_options
    cat <<'EOF'

The mount/device argument is optional: a mounted stick labelled SWISSARMY or
Ventoy is found automatically. An id prefix like "kali" selects every entry
whose id starts with it (kali-netinst, kali-live). See README.md for details.
EOF
}

# --- commands --------------------------------------------------------------

cmd_deps() {
    local -a pkgs=(git curl jq gnupg aria2 pv exfatprogs dosfstools parted xz-utils udisks2 util-linux)
    ((WITH_QEMU)) && pkgs+=(qemu-system-x86 ovmf)
    command -v apt-get >/dev/null || die "apt-get not found; this script targets Ubuntu/Debian"
    log "installing: ${pkgs[*]}"
    as_root apt-get update
    as_root apt-get install -y "${pkgs[@]}"
}

need_device() { [[ -n ${1:-} ]] || die "missing <device> argument (e.g. /dev/sdb)"; }

cmd_install() {
    need_device "${1:-}"
    ventoy_install "$1"
    is_dry_run && return 0
    ok "Ventoy installed. Next: $PROG themes $1 && $PROG isos $1"
}

cmd_update() {
    need_device "${1:-}"
    ventoy_update "$1"
}

cmd_themes() {
    local mnt
    need_cmd git
    mnt=$(resolve_mount "${1:-}")
    themes_install "$mnt"
    ((AUTO_CONFIG)) && cmd_config "$mnt"
    return 0
}

# Is ARG a stick location (path or device) rather than an ISO id?
is_location() { [[ $1 == /* || $1 == .* ]]; }

# expand_ids ARGS...: an exact id, or every id starting with ARG
# ("kali" -> kali-netinst kali-live, "windows" -> windows10 windows11).
expand_ids() {
    local arg id found
    for arg in "$@"; do
        if manifest_has "$arg"; then echo "$arg"; continue; fi
        found=0
        for id in "${ISO_IDS[@]}"; do
            [[ $id == "$arg"* ]] && { echo "$id"; found=1; }
        done
        ((found)) || die "unknown ISO id '$arg' (see isos.conf)"
    done
}

# test_hint MNT: how to boot the stick mounted at MNT in QEMU.
test_hint() {
    local part disk
    part=$(findmnt -no SOURCE "$1" 2>/dev/null || true)
    disk=$(lsblk -no PKNAME "$part" 2>/dev/null || true)
    [[ -n $disk ]] || disk="<device>"
    [[ $disk == /dev/* || $disk == "<device>" ]] || disk=/dev/$disk
    ok "test it: $PROG test $disk   (UEFI: $PROG test $disk --uefi)"
}

cmd_isos() {
    local mnt='' status=0 list id
    local -a ids=()
    need_cmd curl jq sha256sum
    manifest_load
    if (($#)) && is_location "$1"; then
        mnt=$1
        shift
    fi
    # Expand ids before anything else: a typo must abort, not mean "all".
    list=$(expand_ids "$@") || exit 1
    [[ -n $list ]] && mapfile -t ids <<<"$list"
    if ((REPLACE)); then
        # Downloaded ISOs update themselves; --replace is for manual ones.
        [[ -n $FROM_DIR ]] || die "--replace needs --from <dir> with the new ISO"
        ((${#ids[@]})) || die "--replace needs the ids to replace (e.g. windows11)"
        for id in "${ids[@]}"; do
            is_manual "$id" || die "--replace is only for manual ISOs; '$id' is downloaded and updates itself"
        done
    fi
    mnt=$(resolve_mount "$mnt")
    isos_sync "$mnt" "${ids[@]}" || status=$?
    if ((AUTO_CONFIG)); then # not when called from "all", which says it itself
        cmd_config "$mnt"
        is_dry_run || test_hint "$mnt"
    fi
    return "$status"
}

cmd_config() {
    local mnt
    need_cmd jq
    ((${#ISO_IDS[@]})) || manifest_load
    mnt=$(resolve_mount "${1:-}")
    config_write "$mnt"
}

cmd_persistence() {
    local name=${1:-} mnt
    [[ -n $name ]] || die "usage: $PROG persistence <name> [mount|device] [--size MB]"
    manifest_load
    mnt=$(resolve_mount "${2:-}")
    persistence_create "$mnt" "$name" "$SIZE"
    cmd_config "$mnt"
}

cmd_test() {
    local target=${1:-} ovmf
    local -a qemu
    [[ -n $target ]] || die "usage: $PROG test <device|image> [--uefi]"
    need_cmd qemu-system-x86_64
    if [[ -b $target ]]; then
        device_check "$target"
        device_unmount "$target"
    elif [[ ! -f $target ]]; then
        die "$target is neither a block device nor an image file"
    fi
    # zoom-to-fit scales the menu down to the window, so it also
    # works on smaller screens (resize or maximize the window).
    qemu=(qemu-system-x86_64 -m 2G -drive "file=$target,format=raw" -display "gtk,zoom-to-fit=on")
    if [[ -w /dev/kvm ]]; then
        qemu+=(-enable-kvm)
    else
        warn "/dev/kvm is not available, falling back to (slow) software emulation"
    fi
    if ((UEFI)); then
        for ovmf in /usr/share/ovmf/OVMF.fd /usr/share/qemu/OVMF.fd; do
            [[ -f $ovmf ]] && break
        done
        [[ -f $ovmf ]] || die "OVMF not found ($PROG deps --qemu)"
        qemu+=(-bios "$ovmf")
    fi
    log "booting $target in QEMU (close the window to stop)"
    if [[ -b $target && ! -r $target ]]; then
        as_root "${qemu[@]}"
    else
        run "${qemu[@]}"
    fi
}

cmd_all() {
    local dev=${1:-} mnt status=0
    need_device "$dev"
    device_check "$dev"
    log "plan for $dev: deps -> install Ventoy (WIPES $dev) -> label $STICK_LABEL -> themes -> isos -> config"
    cmd_deps
    # A dry run doesn't install Ventoy, so later steps can't verify the stick.
    is_dry_run && STICK_PLANNED=1
    ventoy_install "$dev"
    ventoy_relabel "$dev" "$STICK_LABEL"
    mnt=$(device_mount_data "$dev")
    log "stick mounted at $mnt"
    AUTO_CONFIG=0
    cmd_themes "$mnt"
    cmd_isos "$mnt" || status=$?
    cmd_config "$mnt"
    if ((status)); then
        warn "some ISOs failed; rerun $PROG isos $dev to retry them"
    else
        ok "done. Test it: $PROG test $dev   (UEFI: $PROG test $dev --uefi)"
    fi
    return "$status"
}

# --- argument parsing ------------------------------------------------------

main() {
    local -a args=()
    # Shell completion asks us what can come next (see lib/cli.sh). Handled
    # before parsing, since the words typed so far may include options.
    if [[ ${1:-} == __complete ]]; then
        shift
        cli_complete "$@"
        exit 0
    fi
    while (($#)); do
        case $1 in
            -n | --dry-run) DRY_RUN=1 ;;
            --from) FROM_DIR=${2:?--from needs a directory}; shift ;;
            --from=*) FROM_DIR=${1#*=} ;;
            --replace) REPLACE=1 ;;
            --size) SIZE=${2:?--size needs a value in MB}; shift ;;
            --size=*) SIZE=${1#*=} ;;
            --uefi) UEFI=1 ;;
            --qemu) WITH_QEMU=1 ;;
            -h | --help) usage; exit 0 ;;
            -v | --version) version; exit 0 ;;
            --) shift; args+=("$@"); break ;;
            -*) die "unknown option '$1' (see --help)" ;;
            *) args+=("$1") ;;
        esac
        shift
    done
    ((${#args[@]})) || { usage; exit 1; }
    if [[ -n $FROM_DIR ]]; then
        [[ -d $FROM_DIR ]] || die "--from: '$FROM_DIR' is not a directory"
        FROM_DIR=$(cd "$FROM_DIR" && pwd)
    fi
    is_dry_run && log "dry run: nothing will be changed"

    local cmd=${args[0]}
    args=("${args[@]:1}")
    case $cmd in
        deps) cmd_deps ;;
        install) cmd_install "${args[@]}" ;;
        update) cmd_update "${args[@]}" ;;
        themes) cmd_themes "${args[@]}" ;;
        isos) cmd_isos "${args[@]}" ;;
        config) cmd_config "${args[@]}" ;;
        persistence) cmd_persistence "${args[@]}" ;;
        test) cmd_test "${args[@]}" ;;
        all) cmd_all "${args[@]}" ;;
        ventoy-bump) ventoy_bump "${args[@]}" ;;
        link) link_install ;;
        unlink) link_remove ;;
        help) usage ;;
        *) die "unknown command '$cmd' (see --help)" ;;
    esac
}

main "$@"
