# Contributing

Thanks for helping! Bug reports, new ISOs and fixes for broken download
sources are all welcome.

## Reporting a problem

Upstream projects change their download pages from time to time, so the most
common issue is an ISO that no longer resolves. Use the
[issue templates](https://github.com/migueltc13/swissarmy-usb/issues/new/choose)
and include the output of a dry run, which only reads remote metadata and
changes nothing:

```sh
./setup.sh -n isos <id>
```

## Development setup

```sh
git clone --recurse-submodules https://github.com/migueltc13/swissarmy-usb.git
cd swissarmy-usb
./setup.sh deps --qemu
sudo apt install shellcheck   # and Node.js for prettier
```

## Ground rules

- **Never test on a real disk.** Use `--dry-run` (`-n`) for anything that
  writes, and a loop-device image for real installs. See
  [Testing without a real stick](../README.md#testing-without-a-real-stick).
- **Keep it simple Bash.** Small functions, comments that say why, no new
  dependencies unless Ubuntu ships them.
- **Safety checks stay strict.** Changes to `lib/device.sh` must keep refusing
  non-removable disks, partitions, system mounts and the disk holding `/`.
- **Don't edit `ventoy/` or the theme submodules.** They are kept exactly as
  upstream ships them. Theme tweaks go in `themes/overrides/`, and Ventoy
  updates go through `./setup.sh ventoy-bump <version>`.
- **Never commit ISOs or images.** `.gitignore` excludes `*.iso`, `*.img` and
  `*.dat`.

## Before opening a pull request

```sh
shellcheck -x setup.sh lib/*.sh   # must be clean
npx prettier --check .            # Markdown, JSON and YAML formatting
./setup.sh -n isos /tmp/nostick   # every resolver still finds a release
```

The last one is a dry run against a stick path that doesn't exist, so it
needs no stick and downloads nothing. GitHub Actions runs the same checks on
every pull request, and the resolver check also runs weekly.

For changes to installing, themes or the boot menu, also boot a loop-device
image with `./setup.sh test stick.img` (add `--uefi` for UEFI) and check the
menu.

## Adding an ISO

1. Add an entry to [`isos.conf`](../isos.conf). The header of that file and
   [Adding an ISO](../README.md#adding-an-iso) describe every key.
2. If no existing resolver fits, add `resolve_<name>()` to
   [`lib/resolvers.sh`](../lib/resolvers.sh). It must set at least
   `R_VERSION` and `R_URL`, plus a checksum (`R_SHA256` or `R_SUMS_URL`)
   whenever upstream publishes one. Prefer `verify = sha256+gpg` when the
   project signs its releases, and pin the signing key's fingerprint.
3. Check it with `./setup.sh -n isos <id>`, then download it once for real
   into a loop-device image.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/): a type, an
optional scope and a short imperative summary, with a body that explains why.

```
feat(isos): add Debian netinst
fix(device): refuse disks mounted under /home
docs: explain persistence labels
```

Common types are `feat`, `fix`, `perf`, `docs`, `style` and `refactor`.
