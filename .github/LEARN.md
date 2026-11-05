# Learn: how swissarmy-usb was built

This guide walks through how swissarmy-usb was built, one small piece at a
time, so you can build your own multiboot USB tool (or any careful Bash CLI)
by following along. Each step names the file where the real code lives, so you
can read the full version after the simplified one shown here.

**What you'll learn**

- How to structure a Bash project that is bigger than one script
- How to write a destructive tool that is hard to misuse (dry runs, device
  checks, typed confirmation)
- How to download files and verify them with SHA256 and GPG signatures
- How to parse a simple INI-style config in pure Bash
- How to generate JSON with `jq`
- How to test disk tools without touching a real disk (loop devices + QEMU)
- How to keep `--help`, shell completion and a man page in sync, and check
  it all in GitHub Actions

**What you need**

- Ubuntu (or Debian) and basic Bash knowledge
- A spare USB stick is optional: everything can be tested with an image file

---

## Step 1: Pick the building blocks

Making a USB stick boot many ISOs used to mean writing GRUB configs by hand.
[Ventoy](https://www.ventoy.net) solves the hard part: you install it once on
a stick, then just copy `.iso` files onto its data partition, and it shows
them in a boot menu.

So the project's job is everything _around_ Ventoy:

1. install Ventoy safely on the right disk;
2. download the latest ISOs and prove they weren't tampered with;
3. put them in folders and write Ventoy's config (`ventoy/ventoy.json`) with
   nice menu names, tips and a theme.

Bash was chosen because every tool needed (`lsblk`, `curl`, `gpg`, `jq`,
`sha256sum`) is already a command-line program, and Bash is on every Ubuntu
machine.

## Step 2: A Bash project skeleton

One entry point, `setup.sh`, sources small libraries from `lib/`, each with a
single job (`device.sh`, `isos.sh`, `config.sh`, …).

```bash
#!/usr/bin/env bash
set -euo pipefail   # stop on errors, unset variables and failed pipes

# Find the repo even when setup.sh is run through a symlink.
REPO_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")

source "$REPO_DIR/lib/common.sh"
source "$REPO_DIR/lib/device.sh"
# ...

main() {
    case $1 in
        install) cmd_install "${@:2}" ;;
        isos)    cmd_isos "${@:2}" ;;
        *)       die "unknown command '$1'" ;;
    esac
}
main "$@"
```

`readlink -f` matters: later, `./setup.sh link` puts a symlink in
`~/.local/bin`, and the script must still find its `lib/` folder.

📄 Real code: [`setup.sh`](../setup.sh)

## Step 3: Helpers you'll use everywhere

Before any real feature, write the helpers every command relies on
([`lib/common.sh`](../lib/common.sh)):

```bash
log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# run CMD...: execute, or only print the command in --dry-run mode.
run() {
    if [[ $DRY_RUN == 1 ]]; then
        printf '[dry-run]'; printf ' %q' "$@"; printf '\n'
    else
        "$@"
    fi
} >&2

# as_root CMD...: like run, through sudo when needed.
as_root() { if ((EUID == 0)); then run "$@"; else run sudo "$@"; fi; }

# One scratch directory per run, always cleaned up.
TMP_ROOT=$(mktemp -d)
trap "rm -rf '$TMP_ROOT'" EXIT
```

The key idea: **every command that changes something goes through `run` or
`as_root`**. That gives you a `--dry-run` mode for free, which is how you
develop and test the rest safely. Logs go to stderr so stdout stays clean for
values functions return.

## Step 4: Safety first: never wipe the wrong disk

Installing Ventoy erases a disk, so the device check comes before anything
else ([`lib/device.sh`](../lib/device.sh)). `lsblk` tells you everything you need:

```bash
device_check() {
    local dev=$1
    [[ -b $dev ]] || die "$dev is not a block device"

    case $(lsblk -dno TYPE "$dev") in
        disk) ;;
        part) die "$dev is a partition; pass the whole disk" ;;
        *)    die "$dev is not a whole disk" ;;
    esac

    # Only removable or USB disks.
    [[ $(lsblk -dno RM "$dev") == 1 || $(lsblk -dno TRAN "$dev") == usb ]] \
        || die "$dev is not removable, refusing"

    # Nothing on it may be mounted as /, /home, swap, ...
    while read -r name mnt; do
        [[ -z $mnt || $mnt =~ ^(/media/|/run/media/|/mnt/) ]] \
            || die "$name is mounted at $mnt, refusing"
    done < <(lsblk -nlpo NAME,MOUNTPOINT "$dev")
}
```

Then show the disk and make the user **type its name** (`sdb`) to continue.
There is deliberately no `--yes` flag. Commands that only _add_ files
(`isos`, `themes`) check something weaker but still useful: the disk must
carry Ventoy's `VTOYEFI` partition, so a mounted backup drive is refused.

> 💡 Try it: write `device_check` first and run it against your real system
> disk. It should refuse. That's your first test.

## Step 5: Install Ventoy (and keep it reproducible)

Instead of downloading Ventoy every time, a pinned release is **vendored** in
`ventoy/`, unmodified, with its version and checksum source recorded in
`ventoy/VERSION`. Installing is then one call:

```bash
Ventoy2Disk.sh -I -g -s /dev/sdX   # force install, GPT, Secure Boot support
```

Two lessons from [`lib/ventoy.sh`](../lib/ventoy.sh):

- Ventoy's scripts write logs into their own folder as root. Running them from
  a temporary copy (`cp -a ventoy/ventoy-* "$tmp"`) keeps the repo clean.
- After installing, the exFAT data partition is renamed with
  `exfatlabel <partition> SWISSARMY`, so later commands can find the stick by
  its label without asking for a device.

Updating the vendored copy is a command too (`ventoy-bump <version>`): it
downloads the release, checks it against `sha256.txt`, and replaces the folder.

## Step 6: One manifest describes every ISO

Hard-coding ISOs in the script would make adding one painful. Instead,
[`isos.conf`](../isos.conf) is a small INI file and the single source of truth:

```ini
[folder:2-Disk-Tools]
alias = Disk tools
tip   = Partitioning and cloning

[gparted]
folder = 2-Disk-Tools
file   = gparted.iso
alias  = GParted Live
tip    = Graphical partition editor
source = gparted
verify = sha256
```

Parsing it needs no external tools, just a loop, a regex and an associative
array ([`lib/manifest.sh`](../lib/manifest.sh)):

```bash
declare -A M=()
while IFS= read -r line; do
    [[ -z $line || $line == \#* ]] && continue
    if [[ $line =~ ^\[([^]]+)\]$ ]]; then
        section=${BASH_REMATCH[1]}; continue
    fi
    key=${line%%=*}; value=${line#*=}
    M[$section.${key// /}]=${value# }      # e.g. M[gparted.file]=gparted.iso
done < isos.conf
```

Validate right after loading (required keys, known folders, files ending in
`.iso`), so a typo fails immediately with a line number instead of halfway
through a 40 GB download.

## Step 7: Resolvers find the latest release

Each project publishes ISOs differently. A **resolver** is a small function
per source that only _reads_ remote metadata and fills in a fixed set of
variables ([`lib/resolvers.sh`](../lib/resolvers.sh)):

| Variable     | Meaning                                      |
| ------------ | -------------------------------------------- |
| `R_VERSION`  | version found, e.g. `2026.11.01`             |
| `R_URL`      | download URL                                 |
| `R_SHA256`   | expected hash, if published directly         |
| `R_SUMS_URL` | or: a checksum file that lists the ISO       |
| `R_SIG_URL`  | GPG signature, if the project signs releases |
| `R_SIG_OF`   | what the signature covers: `sums` or `iso`   |

Here is the whole Arch Linux resolver. It scrapes the mirror's file listing:

```bash
resolve_arch() {
    local base=https://geo.mirror.pkgbuild.com/iso
    R_VERSION=$(hrefs "$base/latest/" \
        | sed -nE 's/^archlinux-([0-9.]+)-x86_64\.iso$/\1/p' | sort -V | tail -n 1)
    R_NAME="archlinux-$R_VERSION-x86_64.iso"
    R_URL="$base/latest/$R_NAME"
    R_SUMS_URL="$base/latest/sha256sums.txt"
    R_SIG_URL="$R_URL.sig" R_SIG_OF=iso
}
```

The manifest's `source = arch` picks it, by calling `resolve_$source`. This
contract is why adding a distro is usually 5 to 15 lines. And because
resolvers only read, they also run in `--dry-run`, which lets you check every
source without downloading anything.

## Step 8: Download and verify

This is the heart of the project ([`lib/isos.sh`](../lib/isos.sh)). For each ISO:

1. **Skip if up to date.** After each install, a tiny state file
   (`Files/.swissarmy/<id>.env`) records `VERSION`, `SHA256` and `SIZE`. If the
   resolver finds the same version and the size matches, there's nothing to do.

2. **Download to a `.part` file, hashing on the fly.** Reading a 6 GB ISO back
   from a USB stick is slow, so the hash is computed while the bytes stream in:

   ```bash
   hash=$(curl -fL "$url" | tee "$out" | sha256sum)
   ```

   An interrupted download is resumed later with `curl -C -`.

3. **Check the SHA256** against `R_SHA256` (or the line for `R_NAME` in the
   checksum file). Mismatch → delete the part file and keep the old ISO.

4. **Check the GPG signature** in a throwaway keyring, and accept it only if
   it was made by the **pinned fingerprint** from `isos.conf`, not just "some
   valid key":

   ```bash
   home=$(mktemp -d); chmod 700 "$home"
   curl -fsSL "$key_url" | gpg --homedir "$home" --import
   gpg --homedir "$home" --status-fd 1 --verify "$sig" "$file" \
       | grep -qE "^\[GNUPG:\] VALIDSIG .* $fpr$"
   ```

5. **Move into place** (`mv -f file.part file.iso`) only after every check
   passes, then write the state file.

One surprise worth knowing: Kali Live is only seeded as a torrent, and
torrents write pieces in random order. exFAT has no sparse files, so writing
far into the file first zero-fills everything before it, which looks like a
stall. The fix is `aria2c --file-allocation=prealloc`, and downloading to the
PC first when there's room, then copying to the stick in one pass.

## Step 9: Generate the boot menu config with jq

Ventoy reads `ventoy/ventoy.json`. Rather than editing JSON by hand, it's
generated from a template ([`config/ventoy.tmpl.json`](../config/ventoy.tmpl.json))
plus what's actually on the stick ([`lib/config.sh`](../lib/config.sh)):

```bash
jq -nc --arg i "/2-Disk-Tools/gparted.iso" --arg a "GParted Live" \
    '{alias: {image: $i, alias: $a}}'
```

Each ISO adds an alias (menu name) and a tip (version · language ·
description, built from the state file). The pieces are collected with
`jq -s`, merged into the template, and checked with `jq -e` before the file is
written. Because file names on the stick have no version (`kali-live.iso`),
the config keeps working across updates. A `Files/isos.md` list with versions
and hashes is generated the same way, as a receipt.

## Step 10: Themes

The GRUB themes (Catppuccin, Tokyo Night, Vimix) are **git submodules** in
`themes/`, so they stay exactly as upstream ships them and update with
`git submodule update --remote`. Local changes (the logo, a layout that fits
720p) live in `themes/overrides/<name>/` and are copied on top of the theme on
the stick ([`lib/themes.sh`](../lib/themes.sh)). This "upstream untouched +
overrides" pattern keeps updates painless.

## Step 11: Test without a real stick

You never want to debug a disk tool on a real disk. Linux can turn a file into
a block device:

```bash
truncate -s 8G stick.img
LOOP=$(sudo losetup --show -fP stick.img)
SWISSARMY_ALLOW_LOOP=1 ./setup.sh install "$LOOP"   # explicit opt-in
./setup.sh themes "$LOOP"
./setup.sh test stick.img --uefi                    # boots it in QEMU
sudo losetup -d "$LOOP"
```

`test` runs `qemu-system-x86_64` with the image as a raw drive (`-bios OVMF.fd`
for UEFI, `-enable-kvm` when available), so you see the real boot menu in a
window.

## Step 12: One table for help, completion and the man page

As commands grew, `--help`, bash completion and zsh completion started to
drift apart. The fix was to describe the CLI **once**, as data
([`lib/cli.sh`](../lib/cli.sh)):

```bash
cli_command install "<device>"         disk  "install Ventoy, WIPES the device"
cli_command isos    "[mount|device] [id…]" "stick/ids ids..." "download/verify ISOs"
```

`--help` prints from this table, and the completion scripts ask
`setup.sh __complete <words…>` what can come next, so they can't disagree.
A CI check fails if `--help` lists something the man page
([`share/man/man1/swissarmy-usb.1`](../share/man/man1/swissarmy-usb.1)) doesn't.

## Step 13: Let CI watch for you

Two GitHub Actions workflows ([`.github/workflows/`](workflows)):

- **Lint** runs `shellcheck`, `prettier` and the completion tests on every
  pull request.
- **Resolvers** runs `./setup.sh -n isos /tmp/nostick` every Monday. It's a
  dry run against a path that doesn't exist, so it downloads nothing but
  proves every resolver still finds a release, checksum and signature. When an
  upstream site changes, it **opens an issue** automatically, so you hear
  about it before a user does.

---

## Build your own: exercises

1. Write `device_check` and confirm it refuses your system disk and partitions.
2. Add a `--dry-run` flag and the `run` helper; make sure a dry run changes
   nothing.
3. Parse a two-entry `isos.conf` into an associative array and print it.
4. Write a resolver for a distro of your choice and test it with
   `./setup.sh -n isos <id>`.
5. Download one ISO, verify its SHA256 and GPG signature, and break the
   checksum on purpose to see it rejected.
6. Generate a `ventoy.json` with `jq` and boot it in QEMU from a loop image.

Want to go further? See [CONTRIBUTING.md](CONTRIBUTING.md) for
adding an ISO to this project.
