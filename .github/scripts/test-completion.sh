#!/usr/bin/env bash
# Tests for "setup.sh __complete", which the bash and zsh completions call.
# Run from the repo root: .github/scripts/test-completion.sh
set -euo pipefail

fail=0

# check NAME EXPECTED WORD...: __complete bash WORD... must print EXPECTED
# (space-separated, in order).
check() {
    local name=$1 want=$2 got
    shift 2
    got=$(./setup.sh __complete bash "$@" | tr '\n' ' ' | sed 's/ $//')
    if [[ $got == "$want" ]]; then
        echo "ok   $name"
    else
        echo "FAIL $name"
        echo "     want: $want"
        echo "     got:  $got"
        fail=1
    fi
}

# Expected values come from the same files the tool reads, so the tests
# don't break when an ISO is added.
ids=$(sed -n 's/^\[\([a-z0-9][a-z0-9-]*\)\]$/\1/p' isos.conf | tr '\n' ' ' | sed 's/ $//')
pids=$(awk '/^\[/ { id = "" }
            /^\[[a-z0-9][a-z0-9-]*\]$/ { id = substr($0, 2, length($0) - 2) }
            id != "" && /^persistence[[:space:]]*=/ { print id }' isos.conf | tr '\n' ' ' | sed 's/ $//')

check "commands" "deps install update themes isos config persistence test all ventoy-bump link unlink help" ""
check "commands after an option" "deps install update themes isos config persistence test all ventoy-bump link unlink help" -n ""
check "isos: ISO ids" "$ids" isos ""
check "isos: more ids" "$ids" isos kali-live ""
check "isos: ids after --from DIR" "$ids" --from /tmp isos ""
check "isos: its options" "-n --dry-run --from --replace -h --help -v --version" isos -
check "test: its options" "-n --dry-run --uefi -h --help -v --version" test -
check "--from: directories" ":dirs" isos --from ""
check "--size: no suggestions" "" persistence --size ""
check "persistence: ids with persistence" "$pids" persistence ""
check "update: one device only" "" update /dev/sdz ""
check "ventoy-bump: nothing to suggest" "" ventoy-bump ""

# zsh gets "value:description".
got=$(./setup.sh __complete zsh "" | grep -c '^install:install Ventoy' || true)
if [[ $got == 1 ]]; then echo "ok   zsh: descriptions"; else echo "FAIL zsh: descriptions"; fail=1; fi

exit "$fail"
