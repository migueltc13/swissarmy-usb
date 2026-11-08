# shellcheck shell=bash
# shellcheck disable=SC2034  # the R_* results are read by lib/isos.sh
# One resolver per download source. Each finds the current release (or the
# pinned one) and sets:
#
#   R_VERSION   version string, e.g. 2026.3
#   R_URL       download URL (a .torrent URL when upstream only seeds it)
#   R_NAME      upstream filename, used to look it up in a checksum file
#   R_SHA256    expected SHA256, when upstream publishes it directly
#   R_SUMS_URL  or: URL of a checksum file listing R_NAME
#   R_SIG_URL   GPG signature URL (optional)
#   R_SIG_OF    what R_SIG_URL signs: "sums" or "iso"
#
# Resolvers only read remote metadata, so they run in --dry-run too.
# Add a source by writing resolve_<name>() and using "source = <name>" in
# isos.conf; extra words after the name are passed as arguments.

resolve_reset() {
    R_VERSION='' R_URL='' R_NAME='' R_SHA256='' R_SUMS_URL='' R_SIG_URL='' R_SIG_OF=''
}

# resolve ID: run the resolver named by the entry's "source".
resolve() {
    local id=$1 src name
    local -a args
    resolve_reset
    src=$(m "$id" source)
    read -r -a args <<<"$src"
    name=${args[0]}
    declare -F "resolve_$name" >/dev/null || die "[$id] unknown source '$name'"
    PIN=$(m "$id" pin)
    "resolve_$name" "${args[@]:1}" || return 1
    [[ -n $R_VERSION && -n $R_URL ]] || { warn "[$id] resolver '$name' found no release"; return 1; }
    [[ -n $R_NAME ]] || R_NAME=${R_URL##*/}
}

no_pin() { [[ -z $PIN ]] || die "source '$1' does not support pinning (pin = $PIN)"; }

# hrefs URL: list link targets of an HTML index page.
hrefs() { fetch "$1" | grep -oE 'href="[^"]+"' | sed -E 's/^href="(.*)"$/\1/'; }

# sums_lookup NAME < sumsfile: SHA256 for NAME from a sha256sum-style file
# (also understands "*name" binary markers and GParted's sectioned CHECKSUMS.TXT).
sums_lookup() {
    awk -v f="$1" '{ n=$2; sub(/^\*/, "", n) } n==f && $1 ~ /^[0-9a-fA-F]{64}$/ { print tolower($1); exit }'
}

# --- sources ---------------------------------------------------------------

resolve_arch() {
    local base=https://geo.mirror.pkgbuild.com/iso
    local dir=${PIN:-latest}
    R_VERSION=$(hrefs "$base/$dir/" | sed -nE 's/^archlinux-([0-9.]+)-x86_64\.iso$/\1/p' | sort -V | tail -n 1)
    R_NAME="archlinux-$R_VERSION-x86_64.iso"
    R_URL="$base/$dir/$R_NAME"
    R_SUMS_URL="$base/$dir/sha256sums.txt"
    R_SIG_URL="$R_URL.sig" R_SIG_OF=iso
}

# Since 4.5 the images carry an architecture suffix (omarchy-4.5.0-x86.iso);
# older pinned versions fall back to the unsuffixed name.
resolve_omarchy() {
    local base=https://iso.omarchy.org
    if [[ -n $PIN ]]; then
        R_VERSION=$PIN
    else
        R_VERSION=$(fetch https://omarchy.org | grep -oE 'iso\.omarchy\.org/omarchy-[0-9.]+(-x86)?\.iso' \
            | sed -E 's/.*omarchy-([0-9.]+)(-x86)?\.iso/\1/' | sort -V | tail -n 1)
    fi
    [[ -n $R_VERSION ]] || return 1
    R_URL="$base/omarchy-$R_VERSION-x86.iso"
    curl -fsIL --retry 3 --connect-timeout 20 -o /dev/null "$R_URL" || R_URL="$base/omarchy-$R_VERSION.iso"
    R_SUMS_URL="$R_URL.sha256"
    R_SIG_URL="$R_URL.sig" R_SIG_OF=iso
}

# resolve_ubuntu FLAVOR: newest point release of the pinned series (pin is
# required, e.g. 24.04 -> 24.04.5.1 but never 24.10 or 26.04).
resolve_ubuntu() {
    local flavor=${1:-desktop} base=https://releases.ubuntu.com v
    [[ -n $PIN ]] || die "the ubuntu source needs a pin (e.g. pin = 24.04)"
    local re="^${PIN//./\\.}(\\.[0-9]+)*/?$"
    while read -r v; do
        v=${v%/}
        R_NAME="ubuntu-$v-$flavor-amd64.iso"
        if [[ -n $(fetch "$base/$v/SHA256SUMS" 2>/dev/null | sums_lookup "$R_NAME") ]]; then
            R_VERSION=$v
            R_URL="$base/$v/$R_NAME"
            R_SUMS_URL="$base/$v/SHA256SUMS"
            R_SIG_URL="$base/$v/SHA256SUMS.gpg" R_SIG_OF=sums
            return 0
        fi
    done < <(hrefs "$base/" | grep -E "$re" | sort -Vr -u)
    R_NAME=''
}

# resolve_kali VARIANT: "live" or "installer-netinst" (amd64).
resolve_kali() {
    local variant=$1 base=https://cdimage.kali.org
    local dir=current
    [[ -n $PIN ]] && dir="kali-$PIN"
    R_SUMS_URL="$base/$dir/SHA256SUMS"
    R_NAME=$(fetch "$R_SUMS_URL" | awk '{print $2}' | grep -E "^kali-linux-[0-9.]+-$variant-amd64\.iso$" | head -n 1)
    [[ -n $R_NAME ]] || return 1
    R_VERSION=$(sed -E 's/^kali-linux-([0-9.]+)-.*/\1/' <<<"$R_NAME")
    R_URL="$base/$dir/$R_NAME"
    # Kali only seeds some images (e.g. live) as torrents. Retry, so that a
    # network hiccup doesn't switch an HTTP image to a torrent that doesn't exist.
    curl -fsIL --retry 3 --connect-timeout 20 -o /dev/null "$R_URL" || R_URL="$R_URL.torrent"
    R_SIG_URL="$base/$dir/SHA256SUMS.gpg" R_SIG_OF=sums
}

resolve_tails() {
    local json
    no_pin tails
    json=$(fetch https://tails.net/install/v2/Tails/amd64/stable/latest.json)
    R_VERSION=$(jq -r '.installations[0].version' <<<"$json")
    R_URL=$(jq -r '.installations[0]."installation-paths"[] | select(.type=="iso") | ."target-files"[0].url' <<<"$json")
    R_SHA256=$(jq -r '.installations[0]."installation-paths"[] | select(.type=="iso") | ."target-files"[0].sha256' <<<"$json")
    R_SIG_URL="$R_URL.sig" R_SIG_OF=iso
}

resolve_clonezilla() {
    local base=https://free.nchc.org.tw/clonezilla-live/stable
    no_pin clonezilla
    R_SUMS_URL="$base/SHA256SUMS"
    R_NAME=$(fetch "$R_SUMS_URL" | awk '{print $2}' | grep -E '^clonezilla-live-.*-amd64\.iso$' | head -n 1)
    [[ -n $R_NAME ]] || return 1
    R_VERSION=$(sed -E 's/^clonezilla-live-(.*)-amd64\.iso$/\1/' <<<"$R_NAME")
    R_URL="$base/$R_NAME"
    R_SIG_URL="$base/SHA256SUMS.gpg" R_SIG_OF=sums
}

resolve_gparted() {
    no_pin gparted
    R_SUMS_URL=https://gparted.org/gparted-live/stable/CHECKSUMS.TXT
    R_NAME=$(fetch "$R_SUMS_URL" | grep -oE 'gparted-live-[0-9.-]+-amd64\.iso' | head -n 1)
    [[ -n $R_NAME ]] || return 1
    R_VERSION=$(sed -E 's/^gparted-live-(.*)-amd64\.iso$/\1/' <<<"$R_NAME")
    R_URL="https://downloads.sourceforge.net/gparted/$R_NAME"
}

resolve_systemrescue() {
    if [[ -n $PIN ]]; then
        R_VERSION=$PIN
    else
        R_VERSION=$(fetch https://www.system-rescue.org/Download/ \
            | grep -oE 'releases/[0-9.]+/systemrescue-[0-9.]+-amd64\.iso' \
            | sed -E 's#releases/([0-9.]+)/.*#\1#' | sort -V | tail -n 1)
    fi
    R_URL="https://fastly-cdn.system-rescue.org/releases/$R_VERSION/systemrescue-$R_VERSION-amd64.iso"
    R_SUMS_URL="$R_URL.sha256"
    R_SIG_URL="$R_URL.asc" R_SIG_OF=iso
}

resolve_caine() {
    if [[ -n $PIN ]]; then
        R_VERSION=$PIN
    else
        R_VERSION=$(fetch https://www.caine-live.net/page5/page5.html \
            | grep -oE 'caine[0-9.]+\.iso\.sha256\.txt' \
            | sed -E 's/^caine([0-9.]+)\.iso.*/\1/' | sort -V | tail -n 1)
    fi
    R_NAME="caine$R_VERSION.iso"
    R_URL="https://www.caine-live.net/Downloads/$R_NAME"
    R_SUMS_URL="https://www.caine-live.net/page5/$R_NAME.sha256.txt"
}

# resolve_sourceforge PROJECT [REGEX]: the project's "best release" (the
# file SourceForge offers on its big download button), plus its SHA256.
# REGEX guards against the project switching that file to something else.
resolve_sourceforge() {
    local project=$1 regex=${2:-} json file date
    no_pin sourceforge
    json=$(fetch "https://sourceforge.net/projects/$project/best_release.json")
    file=$(jq -r '.release.filename' <<<"$json")
    date=$(jq -r '.release.date' <<<"$json" | cut -d' ' -f1)
    if [[ -n $regex && ! $file =~ $regex ]]; then
        warn "sourceforge/$project: best release is '$file', which does not match $regex"
        return 1
    fi
    R_NAME=${file##*/}
    R_SHA256=$(jq -r '.release.sha256sum' <<<"$json")
    R_URL="https://downloads.sourceforge.net/project/$project$file"
    # Prefer a version from the filename; fall back to the upload date.
    R_VERSION=$(grep -oE '[0-9]+\.[0-9.]+(-[0-9.]+)?' <<<"${R_NAME%.iso}" | head -n 1)
    R_VERSION=${R_VERSION:-$date}
}

# Kaspersky Rescue Disk has one ever-updated URL and no published checksum;
# the Last-Modified date stands in for a version.
resolve_krd() {
    local modified
    no_pin krd
    R_URL=https://rescuedisk.s.kaspersky-labs.com/updatable/2018/krd.iso
    # Retry on any error: Kaspersky's server now and then refuses requests
    # (seen from GitHub Actions runners) and answers fine moments later.
    modified=$(curl -fsIL --retry 3 --retry-all-errors --retry-delay 3 --connect-timeout 20 "$R_URL" \
        | tr -d '\r' | sed -n 's/^[Ll]ast-[Mm]odified: //p' | tail -n 1)
    [[ -n $modified ]] || return 1
    R_VERSION=$(date -u -d "$modified" +%Y-%m-%d)
}
