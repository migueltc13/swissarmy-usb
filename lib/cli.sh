# shellcheck shell=bash
# The command line in one table. --help and shell completion both read it,
# so they can't disagree. A new command or option is a line here, its code in
# setup.sh, and a line in the man page (CI checks that one).

CLI_CMDS=()
CLI_OPTS=()
declare -A CLI_ARGS=() CLI_POS=() CLI_DESC=() OPT_VALUE=() OPT_FOR=() OPT_DESC=()

# cli_command NAME ARGS POSITIONALS DESCRIPTION
#   ARGS         the arguments as shown in --help
#   POSITIONALS  what each argument completes to, space-separated:
#                  disk       removable/USB disks (what "install" accepts)
#                  stick      mounted sticks, then USB disks
#                  ids        ISO ids from isos.conf
#                  pids       ISO ids that support persistence
#                  image      USB disks and *.img files
#                  stick/ids  a stick when the word looks like a path, else ids
#                a trailing "..." repeats the last one
#   DESCRIPTION  may hold a newline for a second --help line
cli_command() {
    CLI_CMDS+=("$1")
    CLI_ARGS[$1]=$2 CLI_POS[$1]=$3 CLI_DESC[$1]=$4
}

# cli_option SPELLINGS VALUE COMMANDS DESCRIPTION
#   SPELLINGS  as shown in --help, e.g. "-n, --dry-run" or "--from <dir>"
#              (a <value> means the option takes one)
#   VALUE      what that value completes to: "dir", or "-" for nothing
#   COMMANDS   the commands it applies to, or "*" for all
cli_option() {
    CLI_OPTS+=("$1")
    OPT_VALUE[$1]=$2 OPT_FOR[$1]=$3 OPT_DESC[$1]=$4
}

cli_command deps        "[--qemu]"                "" "apt install the required tools (+ QEMU/OVMF)"
cli_command install     "<device>"                disk "install Ventoy (GPT + Secure Boot), WIPES the device"
cli_command update      "<device>"                disk "update Ventoy on an existing stick (keeps files)"
cli_command themes      "[mount|device]"          stick "copy the GRUB themes to ventoy/theme/"
cli_command isos        "[mount|device] [id…]"    "stick/ids ids..." "download/verify ISOs (all, or the given ids)"
cli_command config      "[mount|device]"          stick "regenerate ventoy/ventoy.json and Files/isos.md"
cli_command persistence "<name> [mount|device] [--size MB]" "pids stick" "create ventoy/persistence/<name>.dat"
cli_command test        "<device|image> [--uefi]" image "boot the stick in QEMU"
cli_command all         "<device>"                disk "deps, install, relabel, themes, isos, config"
cli_command ventoy-bump "<version>"               "" "vendor another Ventoy release"
cli_command link        ""                        "" $'add the swissarmy-usb command, man page and\nshell completion (bash, zsh) in ~/.local'
cli_command unlink      ""                        "" "remove those symlinks again"
cli_command help        ""                        "" "show this help"

cli_option "-n, --dry-run" -   "*"         "print what would be done; change nothing"
cli_option "--from <dir>"  dir isos        "copy manual ISOs (Windows, Redo Rescue) from <dir>"
cli_option "--replace"     -   isos        $'isos: replace manual ISOs already on the stick with the\nones in --from (manual ISOs only; needs their ids)'
cli_option "--size <MB>"   -   persistence "persistence image size (default 4096)"
cli_option "--uefi"        -   test        "test: boot with OVMF (UEFI) instead of BIOS"
cli_option "--qemu"        -   deps        "deps: also install qemu-system-x86 and ovmf"
cli_option "-h, --help"    -   "*"         "show this help"
cli_option "-v, --version" -   "*"         "show the version"

# --- --help ----------------------------------------------------------------

# cli_help_row WIDTH KEY DESCRIPTION: one aligned --help entry. A KEY wider
# than its column gets a line of its own. Widths count characters, not bytes
# (the "…" in "[id…]").
cli_help_row() {
    local LC_ALL=C.UTF-8
    local width=$1 key=$2 line
    if ((${#key} > width)); then
        printf '  %s\n' "$key"
        key=''
    fi
    while IFS= read -r line; do
        printf '  %s%*s %s\n' "$key" $((width - ${#key})) '' "$line"
        key=''
    done <<<"$3"
}

cli_help_commands() {
    local name key
    for name in "${CLI_CMDS[@]}"; do
        [[ $name == help ]] && continue # "-h, --help" covers it
        key=$name
        [[ -n ${CLI_ARGS[$name]} ]] && printf -v key '%-7s %s' "$name" "${CLI_ARGS[$name]}"
        cli_help_row 29 "$key" "${CLI_DESC[$name]}"
    done
}

cli_help_options() {
    local opt
    for opt in "${CLI_OPTS[@]}"; do
        cli_help_row 16 "$opt" "${OPT_DESC[$opt]}"
    done
}

# --- completion ------------------------------------------------------------

# cli_spellings SPEC: the option names in a spec ("-n, --dry-run" -> -n --dry-run).
cli_spellings() {
    local -a parts
    local p
    read -r -a parts <<<"${1//,/ }"
    for p in "${parts[@]}"; do
        [[ $p == -* ]] && printf '%s\n' "$p" # not echo: "echo -n" prints nothing
    done
    return 0
}

# cli_opt_spec WORD: the table entry for option WORD, if there is one.
cli_opt_spec() {
    local spec s
    for spec in "${CLI_OPTS[@]}"; do
        while read -r s; do
            [[ $s == "$1" ]] && { echo "$spec"; return 0; }
        done < <(cli_spellings "$spec")
    done
    return 1
}

# cli_emit SHELL VALUE DESCRIPTION: one completion candidate. zsh shows the
# description next to the value; bash only takes the value.
cli_emit() {
    if [[ $1 == zsh ]]; then
        printf '%s:%s\n' "${2//:/\\:}" "${3%%$'\n'*}"
    else
        printf '%s\n' "$2"
    fi
}

# Removable or USB whole disks (the only ones "install" accepts), skipping
# empty card-reader slots.
cli_disks() {
    local dev
    while read -r dev; do
        cli_emit "$1" "$dev" "$(lsblk -dno SIZE,MODEL "$dev" 2>/dev/null | xargs)"
    done < <(lsblk -dnbpo NAME,TYPE,RM,SIZE,TRAN 2>/dev/null \
        | awk '$2 == "disk" && $4 > 0 && ($3 == 1 || $5 == "usb") { print $1 }')
}

# Mounted sticks (labelled SWISSARMY or Ventoy).
cli_sticks() {
    local mnt
    while read -r mnt; do
        cli_emit "$1" "$mnt" "mounted stick"
    done < <(lsblk -nlo LABEL,MOUNTPOINT 2>/dev/null \
        | awk '($1 == "SWISSARMY" || $1 == "Ventoy") && $2 != "" { print $2 }')
}

# cli_ids SHELL [persistence]: ISO ids, optionally only those with persistence.
cli_ids() {
    local id
    manifest_load
    for id in "${ISO_IDS[@]}"; do
        [[ ${2:-} == persistence && -z $(m "$id" persistence) ]] && continue
        cli_emit "$1" "$id" "$(m "$id" alias)"
    done
}

# cli_complete SHELL WORD...: print what can come next. The last WORD is the
# one being completed (possibly empty); the shell filters by it. Two special
# lines ask the shell to complete files itself: ":dirs" (directories) and
# ":img" (*.img files).
cli_complete() {
    local shell=$1
    shift
    (($#)) || set -- ''
    local -a words=("$@") kinds
    local cur=${words[-1]} prev='' cmd='' npos=0 i w spec kind name s

    # The command is the first word that isn't an option or an option's value.
    for ((i = 0; i < ${#words[@]} - 1; i++)); do
        w=${words[i]}
        if [[ $w == -* ]]; then
            # Skip its value too. (Not ((i++)): that "fails" when i was 0,
            # which stops the script under set -e.)
            if spec=$(cli_opt_spec "$w") && [[ $spec == *'<'* ]]; then
                i=$((i + 1))
            fi
        elif [[ -z $cmd ]]; then
            cmd=$w
        else
            npos=$((npos + 1))
        fi
    done
    ((${#words[@]} > 1)) && prev=${words[-2]}

    # The value of an option such as --from.
    if [[ $prev == -* ]] && spec=$(cli_opt_spec "$prev") && [[ $spec == *'<'* ]]; then
        [[ ${OPT_VALUE[$spec]} == dir ]] && echo ':dirs'
        return 0
    fi

    if [[ $cur == -* ]]; then
        for spec in "${CLI_OPTS[@]}"; do
            if [[ -z $cmd || ${OPT_FOR[$spec]} == "*" || " ${OPT_FOR[$spec]} " == *" $cmd "* ]]; then
                while read -r s; do
                    cli_emit "$shell" "$s" "${OPT_DESC[$spec]}"
                done < <(cli_spellings "$spec")
            fi
        done
        return 0
    fi

    if [[ -z $cmd ]]; then
        for name in "${CLI_CMDS[@]}"; do
            cli_emit "$shell" "$name" "${CLI_DESC[$name]}"
        done
        return 0
    fi

    # A positional argument of $cmd.
    [[ -n ${CLI_POS[$cmd]+set} ]] || return 0
    read -r -a kinds <<<"${CLI_POS[$cmd]}"
    ((${#kinds[@]})) || return 0
    if ((npos < ${#kinds[@]})); then
        kind=${kinds[npos]}
    elif [[ ${kinds[-1]} == *... ]]; then
        kind=${kinds[-1]}
    else
        return 0
    fi
    kind=${kind%...}
    if [[ $kind == stick/ids ]]; then
        if [[ $cur == /* || $cur == .* ]]; then kind=stick; else kind=ids; fi
    fi
    case $kind in
        disk) cli_disks "$shell" ;;
        stick) cli_sticks "$shell"; cli_disks "$shell" ;;
        ids) cli_ids "$shell" ;;
        pids) cli_ids "$shell" persistence ;;
        image) cli_disks "$shell"; echo ':img' ;;
    esac
}
