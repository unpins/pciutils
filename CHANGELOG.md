# Changelog

## [Unreleased]

### Fixed

- `unpin install pciutils` now creates the commands. In the v3.15.0-1 release
  it created only `pciutils` itself: the list of program names never made it
  into the published binary, so `lspci` and `setpci` were installed nowhere.
- The binary no longer carries a path into the machine that built it. The
  fallback location for the PCI ID database was compiled in as that machine's
  own store path — a directory that does not exist even there, since the
  on-disk copy is dropped in favour of the embedded one. It points at
  `/usr/share/misc` now, where the distributions keep it. Name resolution was
  never affected: the database is compiled into the binary and no file is
  opened for it.

### Changed

- Two manual pages are no longer embedded: `pcilib.7`, which documents the
  libpci C API rather than any program in here, and `pcilmr.8`, whose program
  (PCIe lane margining — root-only, Linux-only, needs system preparation) is
  deliberately not part of this binary. What remains is `lspci.8`, `setpci.8`
  and `pci.ids.5`.
