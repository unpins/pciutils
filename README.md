# pciutils

Standalone build of [pciutils](https://github.com/pciutils/pciutils) — `lspci` (list PCI devices) and `setpci` (read/write PCI configuration space), in a single binary.

[![CI](https://github.com/unpins/pciutils/actions/workflows/pciutils.yml/badge.svg)](https://github.com/unpins/pciutils/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-⚠-yellow?logo=apple&logoColor=white)

Part of the [unpins](https://unpins.org) project — native single-binary builds with no third-party runtime dependencies.

## Usage

Run `lspci` with [unpin](https://github.com/unpins/unpin):

```bash
unpin lspci
```

To install it onto your PATH:

```bash
unpin install pciutils
```

`unpin install pciutils` also creates the `setpci` command, which reads and writes PCI configuration space.

Listing devices needs no privilege on Linux and Windows — no `sudo`, no administrator, no driver. `setpci` (and the deep `lspci -vvv` dump) reads or writes configuration space, which needs root. macOS restricts PCI access at the OS level; see Build notes.

## Build locally

```bash
nix build github:unpins/pciutils
./result/bin/pciutils --version
```

Or run directly:

```bash
nix run github:unpins/pciutils -- --version
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/pciutils/releases) page has standalone binaries for manual download.

## Build notes

- One multicall binary holds both programs. `pciutils` is the canonical name (a
  busybox-style dispatcher); `lspci` and `setpci` dispatch on `argv[0]`. They
  share `common.o` and the static `libpci`, linked once.
- The PCI ID database (`pci.ids`) is embedded, so `lspci` resolves
  vendor/device names with no companion file; `lspci -i <file>` overrides it.
  Both man pages (`lspci.8`, `setpci.8`) are embedded too — `unpin man lspci` /
  `unpin man setpci`.
- Backends: Linux sysfs, Windows `cfgmgr32` (driverless — `lspci` lists with no
  admin, but `setpci` cannot write there), macOS IOKit. Windows is cross-built
  with mingw; the `.exe` has no companion DLLs.
- `setpci` does no permission check: run without root it prints `pcilib: Cannot
  open ...` to stderr but still exits 0 — upstream behaviour, so don't rely on
  its exit status to detect a denied write.
- **macOS**: Apple gates PCI configuration space — `lspci` needs *both* root and
  the `debug=0x144` kernel boot-arg (`sudo nvram boot-args=debug=0x144`, reboot,
  SIP relaxed). Without it, `lspci` lists nothing. Shipped for the power users
  who set the boot-arg; there is no portable fix.
- `pcilmr` (PCIe lane margining) is upstream but not included: root-only,
  Linux-only, and inert on Windows/macOS.
