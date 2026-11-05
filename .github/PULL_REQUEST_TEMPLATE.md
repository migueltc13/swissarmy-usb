## What and why

<!-- What does this change, and why? Link the issue it fixes: "Fixes #123". -->

## How it was tested

<!-- e.g. "./setup.sh -n isos debian", a loop-device image booted with
     "./setup.sh test stick.img --uefi". Never test on a real disk. -->

## Checklist

- [ ] `shellcheck -x setup.sh lib/*.sh share/bash-completion/completions/* .github/scripts/*.sh` is clean
- [ ] `.github/scripts/test-completion.sh` passes
- [ ] `npx prettier --check . '!ventoy/**' '!themes/**'` passes
- [ ] New or changed commands/options are in `lib/cli.sh`, the man page and the README
- [ ] Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)

See [CONTRIBUTING.md](https://github.com/migueltc13/swissarmy-usb/blob/main/.github/CONTRIBUTING.md) for details.
