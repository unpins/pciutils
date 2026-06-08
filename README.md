# pciutils

Standalone build of [pciutils](https://github.com/pciutils/pciutils) — `lspci` (list PCI devices) and `setpci` (read/write PCI configuration space), in one binary.

[![CI](https://github.com/unpins/pciutils/actions/workflows/pciutils.yml/badge.svg)](https://github.com/unpins/pciutils/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-⚠-yellow?logo=apple&logoColor=white)

Part of the [unpins](https://unpins.org) project — native single-binary builds with no third-party runtime dependencies.

## Usage

Install with [unpin](https://github.com/unpins/unpin):

```bash
unpin install pciutils
```

That puts three commands on your PATH — `pciutils`, `lspci` and `setpci` (the
single binary answers to all three). List your PCI devices:

```bash
lspci
```

On **Linux** and **Windows** listing works as an ordinary user — no `sudo`, no
administrator, no driver to install. `setpci` and the deep `lspci -vvv` dump need
root (they read/write configuration space); see the notes below. macOS has a
hardware-access limitation, also below.

## Build locally

```bash
nix build github:unpins/pciutils
./result/bin/pciutils          # or: nix run github:unpins/pciutils
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/pciutils/releases) page has standalone binaries for manual download.

## Man pages

`lspci.8` and `setpci.8` are embedded in the binary — read them with
`unpin man lspci` / `unpin man setpci`.

## Notes

**One binary, three names.** `pciutils` is a single executable that dispatches on
its invocation name (busybox-style); `lspci` and `setpci` are recorded inside it
and `unpin` recreates them as commands on your PATH at install. A bare `pciutils`
runs `lspci`.

**Self-contained.** The PCI ID database (`pci.ids`, which turns numeric
vendor/device codes into readable names) is **embedded in the binary**, so names
resolve with no companion file. Point `lspci -i <file>` at your own database to
override it.

**`setpci` and privilege.** `lspci` lists devices and basic details with no
privilege; the deep dump (`lspci -vvv`, extended PCIe capabilities) reads the full
configuration space, which the kernel only exposes to root. `setpci` *writes*
configuration space and so needs root on Linux. Note that pciutils does **no**
permission pre-check: run without privilege, `setpci` tries to open the config
space, the kernel denies it, and it prints `pcilib: Cannot open ...` to stderr —
but **exits 0** (this is upstream behaviour, identical to every distribution's
pciutils, not something this build changes). Don't rely on `setpci`'s exit status
to detect a permission failure.

**`pcilmr` is not included.** Upstream also ships `pcilmr` (PCIe lane margining).
It is root-only, Linux-only, needs special system preparation, and does nothing on
Windows/macOS, so it is left out.

How each OS is read:

- **Linux** — through `/sys/bus/pci`. Ships for six arches: x86_64, aarch64, i686,
  ppc64le, riscv64, armv7l. `lspci` lists devices with no privilege; `setpci`
  writes as root.
- **Windows** — through the Configuration Manager (`cfgmgr32`), the same database
  the Device Manager uses. `lspci` enumerates with no kernel driver and no
  administrator rights. `cfgmgr32` is a read/enumerate interface, so **`setpci`
  cannot write** there (a real config-space write needs a port/kernel driver,
  which this driverless build does not ship).
- **macOS** — ⚠️ **largely non-functional on a stock Mac.** Apple does not expose
  PCI configuration space to user space the way Linux and Windows do: the only
  access path (IOKit's `AppleACPIPlatformExpert`) requires **both** root **and**
  booting with the `debug=0x144` kernel boot argument
  (`sudo nvram boot-args=debug=0x144`, then reboot; this needs SIP relaxed).
  Without that, `lspci` reports *"Cannot find any working access method"* and lists
  nothing. The binary builds and `lspci --version` works, so it is shipped for the
  power users who set the boot-arg — but most macOS users will find it unusable.
  There is no portable fix; the limitation is in macOS itself.
