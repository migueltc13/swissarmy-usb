# shellcheck shell=bash
# "link" / "unlink": make setup.sh a user command (swissarmy-usb), with its
# man page and bash completion, as symlinks into ~/.local. Symlinks keep them
# in step with the clone: a git pull updates all three.

LINK_NAME=swissarmy-usb

# link_pairs: one "SOURCE<TAB>LINK" line per file to link.
link_pairs() {
    local comp=${BASH_COMPLETION_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion}
    # man finds pages in ~/.local/share/man because ~/.local/bin is on PATH.
    printf '%s\t%s\n' \
        "$REPO_DIR/setup.sh" "$HOME/.local/bin/$LINK_NAME" \
        "$REPO_DIR/share/man/man1/$LINK_NAME.1" "$HOME/.local/share/man/man1/$LINK_NAME.1" \
        "$REPO_DIR/share/bash-completion/completions/$LINK_NAME" "$comp/completions/$LINK_NAME"
}

# tilde PATH: PATH with $HOME shown as ~, for messages.
tilde() { printf '%s' "${1/#"$HOME"/\~}"; }

# is_our_link LINK SOURCE: LINK is a symlink that resolves to SOURCE.
is_our_link() { [[ -L $1 && $(readlink -f "$1") == "$(readlink -f "$2")" ]]; }

link_install() {
    local src dst status=0
    while IFS=$'\t' read -r src dst; do
        [[ -e $src ]] || die "missing $(tilde "$src") in the clone"
        if is_our_link "$dst" "$src"; then
            ok "already linked: $(tilde "$dst")"
            continue
        fi
        if [[ -e $dst || -L $dst ]]; then
            # Never replace something we didn't create.
            warn "$(tilde "$dst") already exists and is not a link to this clone; left alone"
            status=1
            continue
        fi
        run mkdir -p "$(dirname "$dst")"
        run ln -s "$src" "$dst"
        is_dry_run || ok "linked $(tilde "$dst")"
    done < <(link_pairs)

    is_dry_run && return "$status"
    case ":$PATH:" in
        *":$HOME/.local/bin:"*)
            log "try: $LINK_NAME --help, man $LINK_NAME (tab completion works in new shells)" ;;
        *)
            warn "$(tilde "$HOME/.local/bin") is not on your PATH yet. On Ubuntu it is added at login"
            warn "once the folder exists, so log out and back in, then run: $LINK_NAME --help" ;;
    esac
    return "$status"
}

link_remove() {
    local src dst
    while IFS=$'\t' read -r src dst; do
        if is_our_link "$dst" "$src"; then
            run rm "$dst"
            is_dry_run || ok "removed $(tilde "$dst")"
        elif [[ -e $dst || -L $dst ]]; then
            warn "$(tilde "$dst") is not a link to this clone; left alone"
        fi
    done < <(link_pairs)
}
