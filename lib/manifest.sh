# shellcheck shell=bash
# isos.conf parser.
#
# After manifest_load:
#   ISO_IDS        ISO ids in manifest order
#   FOLDER_IDS     folder names in manifest order
#   M[<id>.<key>]  every value (folders are stored as "folder:<name>.<key>")

MANIFEST=${MANIFEST:-$REPO_DIR/isos.conf}
declare -A M=()
ISO_IDS=()
FOLDER_IDS=()

manifest_load() {
    local line section='' key value n=0
    [[ -f $MANIFEST ]] || die "manifest not found: $MANIFEST"
    M=() ISO_IDS=() FOLDER_IDS=()
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        line=$(trim "$line")
        [[ -z $line || $line == \#* ]] && continue
        if [[ $line =~ ^\[([^]]+)\]$ ]]; then
            section=${BASH_REMATCH[1]}
            [[ -z ${M[$section.__seen]:-} ]] || die "isos.conf:$n: duplicate section [$section]"
            M[$section.__seen]=1
            if [[ $section == folder:* ]]; then
                FOLDER_IDS+=("${section#folder:}")
            else
                [[ $section =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "isos.conf:$n: bad id '$section'"
                ISO_IDS+=("$section")
            fi
            continue
        fi
        [[ $line == *=* ]] || die "isos.conf:$n: expected 'key = value'"
        [[ -n $section ]] || die "isos.conf:$n: value outside of a [section]"
        key=$(trim "${line%%=*}")
        value=$(trim "${line#*=}")
        M[$section.$key]=$value
    done <"$MANIFEST"
    manifest_validate
}

manifest_validate() {
    local id key folder
    for id in "${ISO_IDS[@]}"; do
        for key in folder file alias source verify; do
            [[ -n ${M[$id.$key]:-} ]] || die "isos.conf: [$id] is missing '$key'"
        done
        folder=${M[$id.folder]}
        [[ -n ${M[folder:$folder.__seen]:-} ]] || die "isos.conf: [$id] uses undeclared folder '$folder'"
        [[ ${M[$id.file]} == *.iso ]] || die "isos.conf: [$id] file must end in .iso"
        case ${M[$id.verify]} in
            sha256 | none) ;;
            sha256+gpg)
                [[ -n ${M[$id.gpg_key]:-} && -n ${M[$id.gpg_fpr]:-} ]] \
                    || die "isos.conf: [$id] verify=sha256+gpg needs gpg_key and gpg_fpr"
                ;;
            *) die "isos.conf: [$id] unknown verify '${M[$id.verify]}'" ;;
        esac
    done
}

# m ID KEY: print a manifest value (empty if unset).
m() { printf '%s' "${M[$1.$2]:-}"; }

manifest_has() { [[ -n ${M[$1.__seen]:-} && $1 != folder:* ]]; }

is_manual() { [[ $(m "$1" source) == manual ]]; }

# Path of the ISO on the stick, relative to its root, e.g. /4-Security/kali-live.iso
iso_path() { printf '/%s/%s' "$(m "$1" folder)" "$(m "$1" file)"; }
