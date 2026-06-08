{
  description = "Standalone build of pciutils (lspci + setpci)";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # Self-contained static pciutils for Linux + macOS + Windows: one binary that
  # folds `lspci` and `setpci` (./multicall.nix), with `lspci`/`setpci` as
  # argv[0] aliases. pci.ids is embedded (./pciutils-embed-ids.patch), so names
  # resolve with no companion file.
  #
  # Backends (from pciutils' lib/configure):
  #   linux  -> linux-sysfs: lspci lists devices with NO privilege (the 64-byte
  #             config header + vendor/device/class attrs are world-readable);
  #             setpci writes config space, which the kernel only allows as root.
  #   windows-> win32-cfgmgr32 (Configuration Manager): lspci enumerates with NO
  #             driver and NO admin. cfgmgr32 is read/enumerate only, so setpci
  #             cannot write there (a real write needs a port/kernel driver).
  #   darwin -> IOKit (-framework IOKit CoreFoundation, both public -> allow-list
  #             OK). lspci builds and `--version` works, but Apple gates the
  #             AppleACPIPlatformExpert user-client: enumeration needs BOTH root
  #             AND the `debug=0x144` kernel boot-arg, so on a stock Mac lspci
  #             lists nothing. setpci is likewise gated. Shipped anyway (works for
  #             the power users who set the boot-arg); the README documents this.
  #
  # setpci note: pciutils does no permission pre-check -- without privilege it
  # tries to open the config space, the kernel denies it, and setpci prints
  # `pcilib: Cannot open ...` to stderr but exits 0 (upstream behaviour, same as
  # every distro). pcilmr (PCIe lane margining) is built upstream but NOT folded:
  # root-only, Linux-only, needs system prep, useless on Windows/macOS.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "pciutils";
      smoke = [ "--version" ];
      # `pciutils --version` dispatches to lspci (defaultApplet) -> "lspci
      # version 3.15.0"; match the version rather than the canonical name.
      smokePattern = "version 3\\.";

      build = pkgs:
        import ./multicall.nix { lib = pkgs.lib // ulib; }
          { inherit pkgs; pciutils = pkgs.pkgsStatic.pciutils; };

      windowsBuild = pkgs:
        import ./multicall.nix { lib = pkgs.lib // ulib; }
          { inherit pkgs; pciutils = (ulib.mingwStaticCross pkgs).pciutils; };
    };
}
