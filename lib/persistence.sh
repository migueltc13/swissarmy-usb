# shellcheck shell=bash
# Optional persistence images (ventoy/persistence/<name>.dat).

# persistence_entry NAME: the ISO id a persistence image belongs to — an
# exact id, or the single entry with a "persistence" label whose id starts
# with NAME (so "kali" finds "kali-live").
persistence_entry() {
    local name=$1 id
    local -a hits=()
    if manifest_has "$name" && [[ -n $(m "$name" persistence) ]]; then
        echo "$name"; return 0
    fi
    for id in "${ISO_IDS[@]}"; do
        [[ $id == "$name"* && -n $(m "$id" persistence) ]] && hits+=("$id")
    done
    ((${#hits[@]} == 1)) || return 1
    echo "${hits[0]}"
}

# persistence_create MNT NAME SIZE_MB
persistence_create() {
    local mnt=$1 name=$2 size=$3 id label out
    local -a args
    [[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "bad persistence name '$name'"
    [[ $size =~ ^[0-9]+$ && $size -ge 64 ]] || die "--size must be a number of MB (>= 64)"
    id=$(persistence_entry "$name") \
        || die "no ISO with persistence support matches '$name' (add 'persistence = <label>' in isos.conf)"
    label=$(m "$id" persistence)
    out="$mnt/ventoy/persistence/$name.dat"
    [[ ! -e $out ]] || die "$out already exists — delete it first to recreate it"

    # Check free space up front rather than failing halfway through dd.
    if [[ -d $mnt ]]; then
        local free_mb
        free_mb=$(($(df -Pk "$mnt" | awk 'NR==2{print $4}') / 1024))
        ((free_mb > size)) || die "not enough space on $mnt (${free_mb} MB free, need ${size} MB)"
    fi

    args=(-s "$size" -t ext4 -l "$label" -o "$out")
    # Debian live-boot (Kali) needs persistence.conf with "/ union".
    [[ $label == persistence ]] && args+=(-c persistence.conf)

    log "creating ${out#"$mnt"} (${size} MB, label $label) for [$id]"
    run mkdir -p "$mnt/ventoy/persistence"
    ventoy_run CreatePersistentImg.sh "${args[@]}"
    ok "persistence image ready — boot $(m "$id" alias) and pick $name.dat in Ventoy's prompt"
}
