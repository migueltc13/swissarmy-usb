# shellcheck shell=bash
# Download, verify and place ISOs on the stick.
#
# Per-ISO state (version, sha256, source, date) lives in
# <stick>/Files/.swissarmy/<id>.env (Files/ is ignored by Ventoy) and is
# what "up to date" checks and Files/isos.md are based on.

FROM_DIR=${FROM_DIR:-}
# --replace: copy manual ISOs from FROM_DIR even when one is already on the stick.
REPLACE=${REPLACE:-0}

state_dir() { echo "$1/Files/.swissarmy"; }

# Torrents are downloaded here first, see download().
cache_dir() { echo "${XDG_CACHE_HOME:-$HOME/.cache}/swissarmy-usb"; }

# gpg_verify KEY_URL FPR SIG FILE: check that SIG is a good signature over
# FILE made by the key with fingerprint FPR, using a throwaway keyring.
gpg_verify() {
    local key_url=$1 fpr=$2 sig=$3 file=$4 home status
    need_cmd gpg
    home=$(make_tmp)
    chmod 700 "$home"
    fetch "$key_url" | gpg --homedir "$home" --batch --quiet --import 2>/dev/null \
        || { warn "could not import key from $key_url"; return 1; }
    status=$(gpg --homedir "$home" --batch --status-fd 1 --verify "$sig" "$file" 2>/dev/null || true)
    # VALIDSIG's last field is the primary key fingerprint (also for subkeys).
    if grep -qE "^\[GNUPG:\] VALIDSIG .* ${fpr// /}$" <<<"$status"; then
        return 0
    fi
    warn "GPG signature check failed for $(basename "$file")"
    return 1
}

write_state() {
    local file=$1
    shift
    if is_dry_run; then
        log "dry-run: would record state in $file"
        return
    fi
    printf '%s\n' "$@" >"$file"
}

# download URL OUT: resumable download (curl -C -, or aria2c for torrents).
# A fresh curl download is hashed on the fly and the SHA256 left in
# OUT.sha256, so the ISO never has to be read back from the (slow) stick.
download() {
    local url=$1 out=$2 dir torrent hash size avail cache iso
    rm -f "$out.sha256"
    if [[ $url == *.torrent ]]; then
        need_cmd aria2c
        torrent=$(make_tmp)/file.torrent
        fetch "$url" >"$torrent" || return 1
        size=$(aria2c -S "$torrent" | sed -n 's/^Total Length: .*(\([0-9,]*\)).*/\1/p' | tr -d ,)
        # Torrents write pieces in random order, which is painfully slow on a
        # USB stick. Download to the PC when it has room (plus 1 GB to spare),
        # then copy to the stick in one sequential pass.
        cache=$(cache_dir)
        mkdir -p "$cache"
        avail=$(df --output=avail -B1 "$cache" | tail -n 1)
        if [[ -d $cache/$(basename "$out").d ]] \
            || { [[ -n $size ]] && ((avail > size + (1 << 30))); }; then
            dir="$cache/$(basename "$out").d"
            rm -rf "$out.d"
        else
            dir="$out.d"
            warn "not enough free space in $cache, downloading straight to the stick (slow)"
        fi
        mkdir -p "$dir"
        log "downloading via BitTorrent into $dir (upstream only seeds this image)"
        # No DHT: the torrent's own trackers find the peers, and DHT only adds
        # a scary but harmless "Failed to load DHT routing table" error.
        # Preallocate: exFAT can't hold sparse files, so the first piece written
        # far into the file zero-fills everything before it: a silent stall at
        # 0 B. Preallocating does that work up front, with a FileAlloc progress.
        aria2c --dir "$dir" --seed-time=0 --continue=true --file-allocation=prealloc \
            --enable-dht=false --enable-dht6=false --disk-cache=64M \
            --summary-interval=0 --console-log-level=warn "$torrent" >&2 || return 1
        # Single-file torrent: move (or, from the PC, copy) the payload to OUT.
        iso=$(find "$dir" -type f -name '*.iso' | head -n 1)
        [[ -n $iso ]] || return 1
        if [[ $dir == "$out.d" ]]; then
            mv "$iso" "$out"
        else
            hash=$(copy_hash "$iso" "$out") || return 1
            echo "$hash" >"$out.sha256"
        fi
        rm -rf "$dir"
    elif [[ -s $out ]]; then
        # Resuming: the SHA256 is computed from the whole file afterwards.
        nowrap curl -fL --progress-bar --retry 3 --connect-timeout 20 -C - -o "$out" "$url"
    else
        hash=$(nowrap curl -fL --progress-bar --retry 3 --connect-timeout 20 "$url" \
            | tee "$out" | sha256sum) || return 1
        echo "${hash%% *}" >"$out.sha256"
    fi
}

# iso_fetch MNT ID: resolve, download if needed, verify, install.
# Echoes one of: ok skip fail.
iso_fetch() {
    local mnt=$1 id=$2 verify dest state part tmp actual='' got_dl=1
    verify=$(m "$id" verify)
    dest="$mnt$(iso_path "$id")"
    state="$(state_dir "$mnt")/$id.env"

    if ! resolve "$id"; then
        warn "[$id] could not determine the latest release"
        echo fail; return
    fi
    log "[$id] latest: $R_VERSION"

    if [[ -f $dest && $(kv_get "$state" VERSION) == "$R_VERSION" \
        && $(stat -c %s "$dest") == "$(kv_get "$state" SIZE)" ]]; then
        ok "[$id] $(m "$id" file) $R_VERSION is up to date"
        echo skip; return
    fi

    tmp=$(make_tmp)
    if [[ -n $R_SUMS_URL ]]; then
        fetch "$R_SUMS_URL" >"$tmp/sums" || { warn "[$id] could not fetch $R_SUMS_URL"; echo fail; return; }
    fi
    if [[ $verify == sha256+gpg ]]; then
        if [[ -z $R_SIG_URL ]]; then
            warn "[$id] verify=sha256+gpg but the source provides no signature"
            echo fail; return
        fi
        if [[ $R_SIG_OF == sums ]]; then
            if ! { fetch "$R_SIG_URL" >"$tmp/sums.sig" \
                && gpg_verify "$(m "$id" gpg_key)" "$(m "$id" gpg_fpr)" "$tmp/sums.sig" "$tmp/sums"; }; then
                warn "[$id] checksum file signature is not valid"
                echo fail; return
            fi
            ok "[$id] checksum file signed by $(m "$id" gpg_fpr)"
        fi
    fi
    if [[ -z $R_SHA256 && -f $tmp/sums ]]; then
        R_SHA256=$(sums_lookup "$R_NAME" <"$tmp/sums")
    fi
    if [[ $verify != none && ! $R_SHA256 =~ ^[0-9a-f]{64}$ ]]; then
        warn "[$id] no SHA256 found for $R_NAME"
        echo fail; return
    fi

    if is_dry_run; then
        log "dry-run: [$id] would download $R_URL"
        log "dry-run: [$id]   -> ${dest#"$mnt"} (verify: $verify${R_SHA256:+, sha256 ${R_SHA256:0:16}…})"
        echo ok; return
    fi

    mkdir -p "$(dirname "$dest")" "$(state_dir "$mnt")/partial"
    part="$(state_dir "$mnt")/partial/$id-$R_VERSION.part"
    # Partial downloads of other versions can't be resumed; drop them, on the
    # stick and in the PC's torrent cache (those can be several GB each).
    find "$(state_dir "$mnt")/partial" "$(cache_dir)" -maxdepth 1 -name "$id-*" \
        ! -name "$(basename "$part")*" -exec rm -rf {} + 2>/dev/null || true
    log "[$id] downloading $R_URL"
    download "$R_URL" "$part" || got_dl=0
    if [[ $got_dl == 1 && -f $part.sha256 ]]; then
        actual=$(<"$part.sha256") # hashed while downloading
    fi
    rm -f "$part.sha256"
    if [[ $got_dl == 0 ]]; then
        # Keep the partial download: the next run resumes it.
        warn "[$id] download failed or interrupted; rerun to resume"
        echo fail; return
    fi

    if [[ $verify != none ]]; then
        if [[ -z $actual ]]; then
            log "[$id] verifying SHA256"
            actual=$(sha256_progress "$part" "$(m "$id" file)")
        fi
        if [[ $actual != "$R_SHA256" ]]; then
            warn "[$id] SHA256 mismatch (got ${actual:-nothing}, want $R_SHA256), deleted"
            rm -f "$part"
            echo fail; return
        fi
        ok "[$id] SHA256 ok"
    else
        warn "[$id] upstream publishes no checksum, not verified"
    fi
    if [[ $verify == sha256+gpg && $R_SIG_OF == iso ]]; then
        if ! { fetch "$R_SIG_URL" >"$tmp/iso.sig" \
            && gpg_verify "$(m "$id" gpg_key)" "$(m "$id" gpg_fpr)" "$tmp/iso.sig" "$part"; }; then
            warn "[$id] GPG signature invalid, deleted"
            rm -f "$part"
            echo fail; return
        fi
        ok "[$id] GPG signature ok"
    fi

    mv -f "$part" "$dest"
    write_state "$state" "VERSION=$R_VERSION" "NAME=$R_NAME" "URL=$R_URL" \
        "SHA256=${R_SHA256:-${actual:-$(sha256_progress "$dest")}}" \
        "DATE=$(date -u +%Y-%m-%d)" "SIZE=$(stat -c %s "$dest")"
    ok "[$id] installed ${dest#"$mnt"} ($R_VERSION)"
    echo ok
}

# iso_manual MNT ID: ISOs we can't download (Windows, Redo Rescue). Copies
# them from --from <dir> when given, otherwise explains where to get them.
# One already on the stick is kept, unless --replace asks for a fresh copy.
# Echoes one of: ok skip missing fail.
iso_manual() {
    local mnt=$1 id=$2 dest state src='' cand sha part
    dest="$mnt$(iso_path "$id")"
    state="$(state_dir "$mnt")/$id.env"

    if [[ -f $dest && $REPLACE != 1 ]]; then
        if [[ ! -f $state ]]; then
            log "[$id] found $(m "$id" file), recording its checksum"
            write_state "$state" "VERSION=manual" "NAME=$(m "$id" file)" "URL=$(m "$id" url)" \
                "SHA256=$(is_dry_run || sha256_progress "$dest")" \
                "DATE=$(date -u -r "$dest" +%Y-%m-%d)" "SIZE=$(stat -c %s "$dest")"
        fi
        ok "[$id] $(m "$id" file) is present (manual)"
        echo skip; return
    fi

    if [[ -n $FROM_DIR ]]; then
        if [[ -f $FROM_DIR/$(m "$id" file) ]]; then
            src="$FROM_DIR/$(m "$id" file)"
        elif [[ -n $(m "$id" match) ]]; then
            # Newest-looking match wins, e.g. Win11_25H2_* over Win11_24H2_*.
            while IFS= read -r cand; do src=$cand; done < <(
                find "$FROM_DIR" -maxdepth 1 -type f -name "$(m "$id" match)" | sort -V)
        fi
    fi
    if [[ -z $src && -f $dest ]]; then
        # --replace without a new file: keep the one on the stick.
        warn "[$id] nothing matching $(m "$id" match) in $FROM_DIR, keeping $(m "$id" file)"
        echo fail; return
    fi
    if [[ -z $src ]]; then
        warn "[$id] MISSING, manual download: $(m "$id" url)"
        warn "[$id]   then: $PROG isos --from ~/Downloads $id   (or copy it to $(iso_path "$id"))"
        echo missing; return
    fi

    log "[$id] copying $src"
    [[ -f $dest ]] && log "[$id] replacing $(m "$id" file) once the copy is complete"
    if is_dry_run; then
        run cp "$src" "$dest"
        echo ok; return
    fi
    mkdir -p "$(dirname "$dest")" "$(state_dir "$mnt")/partial"
    part="$(state_dir "$mnt")/partial/$id.part"
    sha=$(copy_hash "$src" "$part") || { rm -f "$part"; echo fail; return; }
    mv -f "$part" "$dest"
    write_state "$state" "VERSION=$(basename "$src" .iso)" "NAME=$(basename "$src")" \
        "URL=$(m "$id" url)" "SHA256=$sha" \
        "DATE=$(date -u +%Y-%m-%d)" "SIZE=$(stat -c %s "$dest")"
    ok "[$id] installed ${dest#"$mnt"}"
    echo ok
}

# isos_layout MNT: folders, Files/.ventoyignore and the state directory.
isos_layout() {
    local mnt=$1 folder
    for folder in "${FOLDER_IDS[@]}"; do
        [[ -d $mnt/$folder ]] || run mkdir -p "$mnt/$folder"
    done
    run mkdir -p "$mnt/Files" "$(state_dir "$mnt")" "$mnt/ventoy"
    [[ -f $mnt/Files/.ventoyignore ]] || run touch "$mnt/Files/.ventoyignore"
}

# isos_sync MNT [IDS...]
isos_sync() {
    local mnt=$1 id result
    shift
    local -a ids=("$@") done_ok=() skipped=() failed=() missing=()
    ((${#ids[@]})) || ids=("${ISO_IDS[@]}")
    for id in "${ids[@]}"; do
        manifest_has "$id" || die "unknown ISO id '$id' (see isos.conf)"
    done
    isos_layout "$mnt"

    # One run per stick: two at once would write to the same partial
    # downloads. The lock lasts until setup.sh exits, and an aria2c left
    # behind by an interrupted run keeps holding it until it has stopped.
    if ! is_dry_run; then
        exec 9>"$(state_dir "$mnt")/.lock"
        flock -n 9 || die "another $PROG run (or its download) is still working on this stick"
    fi

    for id in "${ids[@]}"; do
        if is_manual "$id"; then
            result=$(iso_manual "$mnt" "$id")
        else
            result=$(iso_fetch "$mnt" "$id")
        fi
        case $result in
            ok) done_ok+=("$id") ;;
            skip) skipped+=("$id") ;;
            missing) missing+=("$id") ;;
            *) failed+=("$id") ;;
        esac
    done

    local verb="updated:   "
    is_dry_run && verb="to update: "
    echo >&2
    log "ISO summary"
    ((${#done_ok[@]})) && ok "$verb ${done_ok[*]}"
    ((${#skipped[@]})) && ok "up to date: ${skipped[*]}"
    ((${#missing[@]})) && warn "missing (manual): ${missing[*]}"
    ((${#failed[@]})) && warn "FAILED:     ${failed[*]}"
    ((${#failed[@]} == 0))
}
