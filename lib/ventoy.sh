# shellcheck shell=bash
# Vendored Ventoy: install, update, relabel and bump.

VENTOY_ROOT="$REPO_DIR/ventoy"
VENTOY_RELEASES=https://github.com/ventoy/Ventoy/releases/download

ventoy_version() {
    local v
    v=$(kv_get "$VENTOY_ROOT/VERSION" VERSION)
    [[ -n $v ]] || die "ventoy/VERSION is missing; run: ./setup.sh ventoy-bump <version>"
    echo "$v"
}

ventoy_dir() {
    local dir
    dir="$VENTOY_ROOT/ventoy-$(ventoy_version)"
    [[ -f $dir/Ventoy2Disk.sh ]] || die "vendored Ventoy not found in $dir"
    echo "$dir"
}

# Ventoy's scripts decompress tools and write logs into their own directory
# (as root). Run them from a throwaway copy so the repo stays clean.
ventoy_workdir() {
    local tmp
    tmp=$(make_tmp)
    cp -a "$(ventoy_dir)" "$tmp/"
    echo "$tmp/$(basename "$(ventoy_dir)")"
}

# ventoy_run SCRIPT ARGS...: run one of Ventoy's scripts as root.
ventoy_run() {
    local script=$1 work
    shift
    if is_dry_run; then
        as_root bash "$(ventoy_dir)/$script" "$@"
        return
    fi
    work=$(ventoy_workdir)
    (cd "$work" && as_root bash "./$script" "$@")
}

ventoy_install() {
    local dev=$1
    device_check "$dev"
    log "installing Ventoy $(ventoy_version) on $dev (GPT, Secure Boot)"
    device_confirm "$dev"
    device_unmount "$dev"
    ventoy_run Ventoy2Disk.sh -I -g -s "$dev"
    is_dry_run || udevadm settle 2>/dev/null || true
}

ventoy_update() {
    local dev=$1
    device_check "$dev"
    device_show "$dev"
    log "updating Ventoy on $dev to $(ventoy_version) (ISOs and config are kept)"
    if ! is_dry_run; then
        confirm "Update Ventoy on $dev?" || die "aborted"
    fi
    device_unmount "$dev"
    ventoy_run Ventoy2Disk.sh -u "$dev"
}

# ventoy_relabel DEV LABEL: rename the exFAT data partition.
ventoy_relabel() {
    local dev=$1 label=$2 part
    part=$(device_data_part "$dev")
    if [[ -z $part ]]; then
        is_dry_run || die "$dev has no data partition"
        part="${dev}1"
    fi
    device_unmount "$dev"
    log "labelling $part as $label"
    as_root exfatlabel "$part" "$label"
    is_dry_run || udevadm settle 2>/dev/null || true
}

# ventoy_bump VERSION: download, verify and vendor a Ventoy Linux release.
ventoy_bump() {
    local version=${1:-} tmp tarball expected actual
    version=${version#v}
    [[ $version =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "usage: setup.sh ventoy-bump <version>  (e.g. 1.1.18)"
    tarball="ventoy-$version-linux.tar.gz"

    log "fetching checksums for Ventoy $version"
    expected=$(fetch "$VENTOY_RELEASES/v$version/sha256.txt" | awk -v f="$tarball" '$2==f{print $1}')
    [[ $expected =~ ^[0-9a-f]{64}$ ]] || die "no SHA256 for $tarball in the release's sha256.txt"

    if is_dry_run; then
        run curl -fL -o "$tarball" "$VENTOY_RELEASES/v$version/$tarball"
        log "dry-run: would verify $expected, extract to ventoy/ventoy-$version and update ventoy/VERSION"
        return
    fi

    tmp=$(make_tmp)
    curl -fL --progress-bar --retry 3 -o "$tmp/$tarball" "$VENTOY_RELEASES/v$version/$tarball"
    actual=$(sha256sum "$tmp/$tarball" | cut -d' ' -f1)
    [[ $actual == "$expected" ]] || die "checksum mismatch for $tarball (got $actual, want $expected)"
    ok "SHA256 verified: $actual"

    mkdir -p "$tmp/x"
    tar -xzf "$tmp/$tarball" -C "$tmp/x"
    [[ -f $tmp/x/ventoy-$version/Ventoy2Disk.sh ]] || die "unexpected tarball layout"
    # The Linux tarball ships without a license; take it from the same tag.
    curl -fsSL "https://raw.githubusercontent.com/ventoy/Ventoy/v$version/COPYING" \
        -o "$tmp/x/ventoy-$version/COPYING" || die "could not fetch Ventoy's COPYING"

    mkdir -p "$VENTOY_ROOT"
    find "$VENTOY_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'ventoy-*' -exec rm -rf {} +
    mv "$tmp/x/ventoy-$version" "$VENTOY_ROOT/"
    cat >"$VENTOY_ROOT/VERSION" <<EOF
VERSION=$version
SHA256=$expected
URL=$VENTOY_RELEASES/v$version/$tarball
SOURCE=https://github.com/ventoy/Ventoy/tree/v$version
EOF
    ok "vendored Ventoy $version in ventoy/ventoy-$version; review and commit it"
}
