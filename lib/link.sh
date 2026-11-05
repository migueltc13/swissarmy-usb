# shellcheck shell=bash
# "link" / "unlink": make setup.sh a user command (swissarmy-usb), with its
# man page and bash and zsh completion, as symlinks into ~/.local. Symlinks
# keep them in step with the clone: a git pull updates them all.

LINK_NAME=swissarmy-usb

# link_pairs: one "SOURCE<TAB>LINK" line per file to link.
link_pairs() {
    local comp=${BASH_COMPLETION_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion}
    # man finds pages in ~/.local/share/man because ~/.local/bin is on PATH.
    # Both completions are linked whatever your shell: each is ignored by the
    # other shell, and you may switch.
    printf '%s\t%s\n' \
        "$REPO_DIR/setup.sh" "$HOME/.local/bin/$LINK_NAME" \
        "$REPO_DIR/share/man/man1/$LINK_NAME.1" "$HOME/.local/share/man/man1/$LINK_NAME.1" \
        "$REPO_DIR/share/bash-completion/completions/$LINK_NAME" "$comp/completions/$LINK_NAME" \
        "$REPO_DIR/share/zsh/site-functions/_$LINK_NAME" "$(zsh_functions_dir)/_$LINK_NAME"
}

zsh_functions_dir() { echo "${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions"; }

# zsh_hint: zsh doesn't search zsh_functions_dir by default; say how to add
# it, unless ~/.zshrc already does. (We don't edit anyone's ~/.zshrc.)
zsh_hint() {
    local dir rc=${ZDOTDIR:-$HOME}/.zshrc
    dir=$(tilde "$(zsh_functions_dir)")
    [[ ${SHELL##*/} == zsh ]] || return 0
    if [[ -f $rc ]] && grep -qF -e "$dir" -e "$(zsh_functions_dir)" "$rc"; then
        return 0
    fi
    log "zsh: add this line to $(tilde "$rc"), before compinit (oh-my-zsh: before"
    log "     'source \$ZSH/oh-my-zsh.sh'), then open a new terminal:"
    # shellcheck disable=SC2016  # $fpath is for the user's ~/.zshrc, printed as is
    printf '\n    fpath=(%s $fpath)\n\n' "$dir" >&2
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
    zsh_hint
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
