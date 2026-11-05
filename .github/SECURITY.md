# Security policy

swissarmy-usb wipes disks and installs boot software, so safety bugs matter.

## Reporting a vulnerability

Please report privately through
[**Report a vulnerability**](https://github.com/migueltc13/swissarmy-usb/security/advisories/new)
(the Security tab), not in a public issue. Include the command you ran, the
`lsblk -o NAME,SIZE,TYPE,RM,TRAN,FSTYPE,LABEL,MOUNTPOINT` output if a disk is
involved, and what happened.

You can expect a first reply within a week. Only the latest commit on `main`
is supported; fixes land there.

## In scope

- **Wrong-disk writes:** any way to make `setup.sh` wipe, partition or write
  to a disk other than the intended Ventoy stick, for example getting past the
  checks in `lib/device.sh` (removable/USB only, no system mounts, typed
  confirmation, `VTOYEFI` partition for non-destructive commands).
- **Verification bypass:** any way to get an ISO accepted that doesn't match
  its upstream SHA256 or GPG signature, or to make `ventoy-bump` vendor a
  Ventoy release that doesn't match its published checksum.
- **Command injection:** shell code executed from `isos.conf`, file names in
  `--from`, or data returned by upstream download pages.

## Out of scope

- Vulnerabilities in **Ventoy** itself:
  [report them to Ventoy](https://github.com/ventoy/Ventoy/security).
- Vulnerabilities in the **ISOs** (Ubuntu, Kali, Tails, …): report them to
  each project.
- **Kaspersky Rescue Disk** has no published checksum, so it is downloaded
  over HTTPS without one. This is documented and flagged in the output.
- Enrolling Ventoy's **Secure Boot** key with MokManager trusts that key on
  the machine. This is how Ventoy's Secure Boot support works and is
  explained in the README.
