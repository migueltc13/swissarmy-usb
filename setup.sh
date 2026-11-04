#!/usr/bin/env bash
# swissarmy-usb — build a multiboot USB stick with Ventoy.
# Run ./setup.sh --help for usage.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

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

STICK_LABEL=SWISSARMY
SIZE=4096
UEFI=0
WITH_QEMU=0
AUTO_CONFIG=1

usage() {
    cat <<'EOF'
Usage: ./setup.sh [--dry-run] <command> [args] [options]

Commands:
  deps [--qemu]                 apt install the required tools (+ QEMU/OVMF)
  install <device>              install Ventoy (GPT + Secure Boot) — WIPES the device
  update  <device>              update Ventoy on an existing stick (keeps files)
  themes  [mount|device]        copy the GRUB themes to ventoy/theme/
  isos    [mount|device] [id…]  download/verify ISOs (all, or the given ids)
  config  [mount|device]        regenerate ventoy/ventoy.json and Files/isos.md
  persistence <name> [mount|device] [--size MB]
                                create ventoy/persistence/<name>.dat
  test    <device|image> [--uefi]
                                boot the stick in QEMU
  all     <device>              deps, install, relabel, themes, isos, config
  ventoy-bump <version>         vendor another Ventoy release

Options:
  -n, --dry-run    print what would be done; change nothing
  --from <dir>     copy manual ISOs (Windows, Redo Rescue) from <dir>
  --size <MB>      persistence image size (default 4096)
  --uefi           test: boot with OVMF (UEFI) instead of BIOS
  --qemu           deps: also install qemu-system-x86 and ovmf
  -h, --help       show this help

The mount/device argument is optional: a mounted stick labelled SWISSARMY or
Ventoy is found automatically. An id prefix like "kali" selects every entry
whose id starts with it (kali-netinst, kali-live). See README.md for details.
EOF
}

# --- commands --------------------------------------------------------------

cmd_deps() {
    local -a pkgs=(git curl jq gnupg aria2 pv exfatprogs dosfstools parted xz-utils udisks2 util-linux)
    ((WITH_QEMU)) && pkgs+=(qemu-system-x86 ovmf)
    command -v apt-get >/dev/null || die "apt-get not found — this script targets Ubuntu/Debian"
    log "installing: ${pkgs[*]}"
    as_root apt-get update
    as_root apt-get install -y "${pkgs[@]}"
}

need_device() { [[ -n ${1:-} ]] || die "missing <device> argument (e.g. /dev/sdb)"; }

cmd_install() {
    need_device "${1:-}"
    ventoy_install "$1"
    is_dry_run && return 0
    ok "Ventoy installed. Next: ./setup.sh themes $1 && ./setup.sh isos $1"
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
    ok "test it: ./setup.sh test $disk   (UEFI: ./setup.sh test $disk --uefi)"
}

cmd_isos() {
    local mnt='' status=0 list
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
    [[ -n $name ]] || die "usage: setup.sh persistence <name> [mount|device] [--size MB]"
    manifest_load
    mnt=$(resolve_mount "${2:-}")
    persistence_create "$mnt" "$name" "$SIZE"
    cmd_config "$mnt"
}

cmd_test() {
    local target=${1:-} ovmf
    local -a qemu
    [[ -n $target ]] || die "usage: setup.sh test <device|image> [--uefi]"
    need_cmd qemu-system-x86_64
    if [[ -b $target ]]; then
        device_check "$target"
        device_unmount "$target"
    elif [[ ! -f $target ]]; then
        die "$target is neither a block device nor an image file"
    fi
    qemu=(qemu-system-x86_64 -enable-kvm -m 2G -drive "file=$target,format=raw")
    if [[ ! -w /dev/kvm ]]; then
        warn "/dev/kvm is not available — falling back to (slow) software emulation"
        qemu=(qemu-system-x86_64 -m 2G -drive "file=$target,format=raw")
    fi
    if ((UEFI)); then
        for ovmf in /usr/share/ovmf/OVMF.fd /usr/share/qemu/OVMF.fd; do
            [[ -f $ovmf ]] && break
        done
        [[ -f $ovmf ]] || die "OVMF not found (./setup.sh deps --qemu)"
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
    ventoy_install "$dev"
    ventoy_relabel "$dev" "$STICK_LABEL"
    mnt=$(device_mount_data "$dev")
    log "stick mounted at $mnt"
    AUTO_CONFIG=0
    cmd_themes "$mnt"
    cmd_isos "$mnt" || status=$?
    cmd_config "$mnt"
    if ((status)); then
        warn "some ISOs failed — rerun ./setup.sh isos $dev to retry them"
    else
        ok "done. Test it: ./setup.sh test $dev   (UEFI: ./setup.sh test $dev --uefi)"
    fi
    return "$status"
}

# --- argument parsing ------------------------------------------------------

main() {
    local -a args=()
    while (($#)); do
        case $1 in
            -n | --dry-run) DRY_RUN=1 ;;
            --from) FROM_DIR=${2:?--from needs a directory}; shift ;;
            --from=*) FROM_DIR=${1#*=} ;;
            --size) SIZE=${2:?--size needs a value in MB}; shift ;;
            --size=*) SIZE=${1#*=} ;;
            --uefi) UEFI=1 ;;
            --qemu) WITH_QEMU=1 ;;
            -h | --help) usage; exit 0 ;;
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
    is_dry_run && log "dry run — nothing will be changed"

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
        help) usage ;;
        *) die "unknown command '$cmd' (see --help)" ;;
    esac
}

main "$@"
