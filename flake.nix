{
  description = "pciutils (lspci + setpci) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # Self-contained static pciutils for Linux + macOS + Windows: one binary that
  # folds `lspci` and `setpci`, with `lspci`/`setpci` as argv[0] aliases. Linux
  # and darwin fold via the unpin-llvm engine (bitcode multicall); Windows folds
  # via the objcopy recipe in ./multicall.nix. pci.ids is embedded
  # (./pciutils-embed-ids.patch), so names resolve with no companion file.
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
      smoke = [ "--unpin-program=lspci" "--version" ];
      # lspci prints "lspci version 3.15.0"; match the version rather than the
      # canonical name.
      smokePattern = "version 3\\.";

      # Build via the unpin-llvm engine + emit a bitcode multicall module. The
      # engine compiles pciutils (lspci + setpci are separate upstream binaries)
      # to bitcode and the standalone self-folds them into one `pciutils` binary
      # on BOTH Linux and darwin — same as htop/tmux. The old objcopy fold in
      # ./multicall.nix is ELF/Mach-O bespoke and can't run on the engine's -flto
      # bitcode objects, so it's now reserved for Windows only (windowsBuild).
      # Pure C — no requires.cxx.
      engine = "unpin-llvm";
      multicall = {
        # The mega relinks from bitcode, so it can't see pciutils' own configure
        # -framework flags (darwin IOKit backend) — declare them here so the
        # mega-link names them. Harmlessly absent from the Linux link.
        requires.frameworks = [ "IOKit" "CoreFoundation" ];
        programs = [ { name = "lspci"; } { name = "setpci"; } ];
      };

      # Linux + darwin: plain pkgsStatic.pciutils compiled to bitcode and
      # self-folded. The pci.ids embed patch + ZLIB=no (so the embed patch's
      # FILE* branch is wired, not the zlib one) go on every platform so lspci
      # resolves vendor/device names with no companion file; pcilmr is built but
      # not folded (root/Linux-only). On darwin the SDK-always engine gives the
      # IOKit backend its frameworks (declared above).
      build = pkgs:
        pkgs.pkgsStatic.pciutils.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [ ./pciutils-embed-ids.patch ];
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.buildPackages.xxd ];
          postPatch = (old.postPatch or "") + ''
            xxd -i -n embedded_pci_ids \
              ${pkgs.buildPackages.hwdata}/share/hwdata/pci.ids > lib/embedded_pci_ids.h
          '' + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
            # pciutils' lib/configure hardcodes `-lresolv` into the darwin
            # WITH_LIBS line, UNCONDITIONALLY (it's on the platform branch, not
            # gated by DNS). With DNS=no the resolver is unused, and the engine's
            # apple-sdk sysroot ships no libresolv to link against, so ld64.lld
            # fails "library not found for -lresolv". Drop just the -lresolv token
            # and keep the -framework CoreFoundation/IOKit the IOKit backend needs.
            substituteInPlace lib/configure \
              --replace-fail \
                'WITH_LIBS+=-lresolv -framework CoreFoundation -framework IOKit' \
                'WITH_LIBS+=-framework CoreFoundation -framework IOKit'
          '';
          # nixpkgs' postInstall copies pci.ids from the HOST `hwdata` into
          # $out/share/pci.ids. We embed pci.ids (postPatch above), so that
          # on-disk copy is redundant — the self-fold binary reads names from
          # the compiled-in db (closure is self-only, no companion file). Worse,
          # the copy drags a HOST-arch hwdata build into the graph, which builds
          # fine natively but breaks the darwin CROSS (arm64 hwdata's builder
          # bash can't exec on the x86_64-darwin build host: "No such file or
          # directory"). Drop the copy; keep only the update-pciids cleanup.
          postInstall = ''
            rm -f $out/sbin/update-pciids $out/man/man8/update-pciids.8
          '';
          # pciutils' Makefile builds its compiler as `$(CROSS_COMPILE)gcc`.
          # pkgsStatic sets CROSS_COMPILE=<triple>-, but the engine cc-wrapper is
          # a single unprefixed clang (`-target` selects the arch), so the
          # prefixed name is "command not found". Drop the prefix so `gcc`
          # resolves to the engine cc; the bintools (ar/ranlib) are present
          # unprefixed too. Correct for native and every cross arch alike.
          makeFlags = (builtins.filter
            (f: !(pkgs.lib.hasPrefix "CROSS_COMPILE=" f)) (old.makeFlags or [ ]))
            ++ [ "ZLIB=no" "CROSS_COMPILE=" ]
            # DNS=no on darwin: names-net.c/names-cache.c (the online pci.ids
            # DNS lookup) #include <arpa/nameser.h> + <resolv.h>, which nixpkgs'
            # apple-sdk doesn't ship — and unlike an unused include they actually
            # call res_query/ns_*, so the TUs can't compile without them. The
            # feature is redundant here anyway (pci.ids is embedded, names
            # resolve offline) and does live network queries against a
            # self-contained binary's grain — Windows already drops it the same
            # way. Linux keeps DNS=yes (musl provides both headers).
            ++ pkgs.lib.optional pkgs.stdenv.hostPlatform.isDarwin "DNS=no";
          doCheck = false;
          doInstallCheck = false;
        });

      windowsBuild = pkgs:
        import ./multicall.nix { lib = pkgs.lib // ulib; }
          { inherit pkgs; pciutils = (ulib.mingwStaticCross pkgs).pciutils; };
    };
}
