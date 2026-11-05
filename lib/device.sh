# shellcheck shell=bash
# Device safety checks and mountpoint detection.
#
# Everything that could wipe a disk goes through device_check first.

# Mountpoints that mean "this disk runs the current system". A disk with any
# of these mounted is refused outright.
SYSTEM_MOUNTS_RE='^(/|/boot(/.*)?|/home(/.*)?|/usr(/.*)?|/var(/.*)?|/opt|/srv|/etc|\[SWAP\])$'

# Set SWISSARMY_ALLOW_LOOP=1 to accept loop devices (testing with losetup).
SWISSARMY_ALLOW_LOOP=${SWISSARMY_ALLOW_LOOP:-0}

lsblk_field() { lsblk -dno "$1" "$2" 2>/dev/null | head -n 1 | xargs; }

# device_check DEV: refuse anything that is not a removable whole disk.
device_check() {
    local dev=$1 type rm tran name mnt

    [[ $dev == /dev/* ]] || die "expected a device path like /dev/sdX, got '$dev'"
    [[ -b $dev ]] || die "$dev is not a block device"

    type=$(lsblk_field TYPE "$dev")
    case $type in
        disk) ;;
        part) die "$dev is a partition; pass the whole disk (e.g. /dev/$(lsblk_field PKNAME "$dev"))" ;;
        loop)
            [[ $SWISSARMY_ALLOW_LOOP == 1 ]] \
                || die "$dev is a loop device (set SWISSARMY_ALLOW_LOOP=1 for testing)"
            warn "$dev is a loop device, accepted because SWISSARMY_ALLOW_LOOP=1"
            ;;
        *) die "$dev has type '$type', expected a whole disk" ;;
    esac

    if [[ $type == disk ]]; then
        rm=$(lsblk_field RM "$dev")
        tran=$(lsblk_field TRAN "$dev")
        if [[ $rm != 1 && $tran != usb ]]; then
            die "$dev is not removable (RM=$rm TRAN=${tran:-none}), refusing"
        fi
    fi

    # Any system partition mounted anywhere on this disk (including LVM/LUKS
    # children, which lsblk lists under the disk) means hands off.
    while read -r name mnt; do
        [[ -n $mnt ]] || continue
        if [[ $mnt =~ $SYSTEM_MOUNTS_RE ]]; then
            die "$name is mounted at $mnt: $dev holds the running system, refusing"
        fi
        # A USB stick lives under /media, /run/media or /mnt. Anything else
        # (/snap/..., /srv/data, ...) is not something we should touch.
        if [[ ! $mnt =~ ^(/media/|/run/media/|/mnt/) ]]; then
            die "$name is mounted at $mnt, which is not a removable-media mount, refusing"
        fi
    done < <(lsblk -nlpo NAME,MOUNTPOINT "$dev")

    # Belt and braces: the disk behind / must never be the target.
    local root_src root_disk
    root_src=$(findmnt -no SOURCE / 2>/dev/null || true)
    if [[ -b $root_src ]]; then
        root_disk=$(lsblk -nspo NAME,TYPE "$root_src" | awk '$2=="disk"{print $1; exit}')
        [[ $root_disk != "$dev" ]] || die "$dev holds the root filesystem, refusing"
    fi
}

device_show() {
    lsblk -o NAME,SIZE,TYPE,RM,TRAN,VENDOR,MODEL,SERIAL,FSTYPE,LABEL,MOUNTPOINT "$1" >&2
}

# device_confirm DEV: show the disk and require the user to type its name.
device_confirm() {
    local dev=$1 answer
    echo >&2
    device_show "$dev"
    echo >&2
    warn "ALL DATA ON $dev WILL BE DESTROYED."
    if is_dry_run; then
        log "dry-run: would ask you to type '$(basename "$dev")' to confirm"
        return 0
    fi
    [[ -r /dev/tty ]] || die "no terminal available to confirm the target device"
    read -r -p "Type the device name ($(basename "$dev")) to confirm: " answer </dev/tty
    [[ $answer == "$(basename "$dev")" || $answer == "$dev" ]] \
        || die "confirmation did not match, nothing was changed"
}

# device_unmount DEV: unmount every mounted partition of DEV.
device_unmount() {
    local name mnt
    while read -r name mnt; do
        [[ -n $mnt && $name != "$1" ]] || continue
        log "unmounting $name ($mnt)"
        if command -v udisksctl >/dev/null 2>&1 && ! is_dry_run \
            && udisksctl unmount -b "$name" >/dev/null 2>&1; then
            continue
        fi
        as_root umount "$name"
    done < <(lsblk -nlpo NAME,MOUNTPOINT "$1")
}

# device_data_part DEV: the first partition (Ventoy's exFAT data partition).
device_data_part() {
    lsblk -nlpo NAME,TYPE "$1" | awk '$2=="part"{print $1; exit}'
}

# device_mount_data DEV: print where the Ventoy data partition is mounted,
# mounting it with udisksctl when needed.
device_mount_data() {
    local dev=$1 part mnt
    part=$(device_data_part "$dev")
    if [[ -z $part ]]; then
        is_dry_run && { echo "/media/$USER/SWISSARMY"; return; }
        die "$dev has no partitions; install Ventoy first"
    fi
    mnt=$(lsblk -no MOUNTPOINT "$part" | head -n 1)
    if [[ -z $mnt ]]; then
        if is_dry_run; then
            log "dry-run: would mount $part"
            echo "/media/$USER/SWISSARMY"
            return
        fi
        need_cmd udisksctl
        udisksctl mount -b "$part" >&2 || die "could not mount $part"
        mnt=$(lsblk -no MOUNTPOINT "$part" | head -n 1)
    fi
    [[ -n $mnt ]] || die "could not find where $part is mounted"
    echo "$mnt"
}

# Set by "all" in dry-run mode: the stick is only about to become a Ventoy
# stick, so stick_check can't confirm it yet.
STICK_PLANNED=0

# is_ventoy_disk DISK: DISK carries Ventoy's VTOYEFI partition.
is_ventoy_disk() { lsblk -nlo LABEL "$1" 2>/dev/null | grep -qx VTOYEFI; }

# stick_check MNT: refuse to write into anything that is not the data
# partition of a Ventoy stick (an internal disk, a backup drive, ...).
stick_check() {
    local mnt=$1 src disk
    ((STICK_PLANNED)) && return 0
    src=$(findmnt -no SOURCE --mountpoint "$mnt" 2>/dev/null | head -n 1)
    disk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -n 1)
    if [[ -z $disk ]] || ! is_ventoy_disk "/dev/$disk"; then
        die "$mnt is not on a Ventoy stick (no VTOYEFI partition on ${disk:+/dev/}${disk:-its disk}), refusing"
    fi
}

# resolve_mount [ARG]: accept a mountpoint, a device, or nothing (auto-detect a
# mounted partition labelled SWISSARMY or Ventoy). Prints the mountpoint after
# checking that it belongs to a Ventoy stick.
resolve_mount() {
    local arg=${1:-} mnt
    if [[ -z $arg ]]; then
        mnt=$(lsblk -nlo LABEL,MOUNTPOINT | awk '($1=="SWISSARMY"||$1=="Ventoy") && $2!=""{print $2; exit}')
        [[ -n $mnt ]] || die "no mounted SWISSARMY/Ventoy stick found; pass a mountpoint or device"
        stick_check "$mnt"
        log "using detected stick at $mnt"
        echo "$mnt"
        return
    fi
    if [[ -b $arg ]]; then
        if [[ $(lsblk_field TYPE "$arg") == part ]]; then
            arg=/dev/$(lsblk_field PKNAME "$arg")
        fi
        # Check before mounting anything.
        ((STICK_PLANNED)) || is_ventoy_disk "$arg" \
            || die "$arg is not a Ventoy stick (no VTOYEFI partition); run: ./setup.sh install $arg"
        device_mount_data "$arg"
        return
    fi
    if [[ -d $arg ]]; then
        mountpoint -q "$arg" || die "$arg is not a mountpoint, refusing to write ISOs into a plain directory"
        stick_check "$arg"
        [[ -w $arg ]] || die "$arg is not writable by $USER (mount it with udisksctl or your file manager)"
        (cd "$arg" && pwd)
        return
    fi
    is_dry_run && { echo "$arg"; return; }
    die "'$arg' is neither a mountpoint nor a block device"
}
