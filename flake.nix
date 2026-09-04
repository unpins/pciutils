{
  description = "pciutils (lspci + setpci) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # Self-contained static pciutils for Linux + macOS + Windows: one binary that
  # folds `lspci` and `setpci`, with `lspci`/`setpci` as argv[0] aliases. Every
  # target folds via the unpin-llvm engine (bitcode multicall). pci.ids is
  # embedded (./pciutils-embed-ids.patch), so names resolve with no companion
  # file.
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
      # Everything both the native and the mingw build need. `pkgs` is the
      # x86_64-linux root in either case (the cross set lives inside
      # mingwStaticCross), so buildPackages resolves the same way.
      pciTweaks = { pkgs, isDarwin ? false, isWindows ? false }: drv:
        drv.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [ ./pciutils-embed-ids.patch ];
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.buildPackages.xxd ];
          # `which` is only used by update-pciids (a runtime script we don't
          # ship); on the mingw cross its which.c calls geteuid() (absent on
          # Windows) and breaks the build, so drop it there.
          buildInputs =
            if isWindows
            then builtins.filter (x: (x.pname or x.name or "") != "which") (old.buildInputs or [ ])
            else (old.buildInputs or [ ]);
          # Bake hwdata's pci.ids into the lib before it compiles.
          postPatch = (old.postPatch or "") + ''
            xxd -i -n embedded_pci_ids \
              ${pkgs.buildPackages.hwdata}/share/hwdata/pci.ids > lib/embedded_pci_ids.h
          '' + pkgs.lib.optionalString isWindows ''
            # lib/i386-io-windows.h uses the compiler's own __readeflags only when
            # __GNUC__ >= 4.9, and clang answers 4.2 to that question — so it took
            # the hand-rolled branch below and redefined an intrinsic clang already
            # has. Route clang to <x86intrin.h>, which is the branch meant for a
            # compiler that provides one.
            substituteInPlace lib/i386-io-windows.h \
              --replace-fail \
                '#elif defined(__GNUC__) && ((__GNUC__ == 4 && __GNUC_MINOR__ >= 9) || (__GNUC__ > 4))' \
                '#elif defined(__clang__) || (defined(__GNUC__) && ((__GNUC__ == 4 && __GNUC_MINOR__ >= 9) || (__GNUC__ > 4)))'
            # Same shape, one file over: init.c aliases __ImageBase onto
            # _image_base__, the name GNU ld used before 2.19 — so the alias
            # points AT the symbol it means to stand in for. lld goes the other
            # way and defines __ImageBase itself, leaving _image_base__ undefined,
            # and clang answers __GNUC__ so the asm gets compiled anyway.
            substituteInPlace lib/init.c \
              --replace-fail '#ifdef __GNUC__' '#if defined(__GNUC__) && !defined(__clang__)'
          '' + pkgs.lib.optionalString isDarwin ''
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
          # on-disk copy is redundant — the folded binary reads names from the
          # compiled-in db (closure is self-only, no companion file). Worse, the
          # copy drags a HOST-arch hwdata build into the graph, which builds fine
          # natively but breaks the darwin CROSS (arm64 hwdata's builder bash
          # can't exec on the x86_64-darwin build host: "No such file or
          # directory"). Drop the copy; keep only the update-pciids cleanup.
          # The man harvest takes the whole `man` output, so prune the pages for
          # things this binary has not got: `pcilib.7` documents the libpci C
          # API (we ship the programs, not the linkable library) and `pcilmr.8`
          # documents a program deliberately left out of the fold (see the
          # header note). Same one-directional guard as everywhere else: it
          # checks that every announced name has a page, never that every page
          # has a program.
          # pciutils' Makefile installs man under $out/man (MANDIR=$PREFIX/man);
          # nixpkgs' fixup moves it to $man/share/man afterwards, so postInstall
          # must use the pre-move path.
          postInstall = ''
            rm -f $out/sbin/update-pciids $out/man/man8/update-pciids.8
            rm -f $out/man/man7/pcilib.7* $out/man/man8/pcilmr.8*
          '';
          # pciutils' Makefile builds its compiler as `$(CROSS_COMPILE)gcc`.
          # The cross sets CROSS_COMPILE=<triple>-, but the engine cc-wrapper is
          # a single unprefixed clang (`-target` selects the arch), so the
          # prefixed name is "command not found". Drop the prefix so `gcc`
          # resolves to the engine cc; the bintools (ar/ranlib) are present
          # unprefixed too. Correct for native and every cross alike.
          makeFlags = (builtins.filter
            (f: !(pkgs.lib.hasPrefix "CROSS_COMPILE=" f)) (old.makeFlags or [ ]))
            # IDSDIR: the compiled-in fallback path for pci.ids. nixpkgs'
            # PREFIX=$out makes it `<store path>/share/pci.ids` — a path on the
            # build machine, and one that does not exist even there once
            # postInstall drops the copy. Names come from the compiled-in db so
            # it is never opened, but a store path in a shipped binary is worth
            # a flag to avoid. Invisible to `nix-store -q --references`: under
            # the engine the fold's inputs are the module archives, not `out`.
            ++ [ "ZLIB=no" "CROSS_COMPILE=" "IDSDIR=/usr/share/misc" ]
            # DNS=no off Linux: names-net.c/names-cache.c (the online pci.ids DNS
            # lookup) #include <arpa/nameser.h> + <resolv.h>, which neither
            # nixpkgs' apple-sdk nor mingw ships — and unlike an unused include
            # they actually call res_query/ns_*, so the TUs can't compile without
            # them. The feature is redundant here anyway (pci.ids is embedded,
            # names resolve offline) and does live network queries against a
            # self-contained binary's grain. Linux keeps DNS=yes (musl provides
            # both headers).
            ++ pkgs.lib.optional (isDarwin || isWindows) "DNS=no";
          doCheck = false;
          doInstallCheck = false;
        });
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
      # on every target — same as htop/tmux. Pure C — no requires.cxx.
      engine = "unpin-llvm";
      multicall = {
        windows = true;
        # The mega relinks from bitcode, so it can't see pciutils' own configure
        # -framework flags (darwin IOKit backend) — declare them here so the
        # mega-link names them. Harmlessly absent from the Linux link.
        requires.frameworks = [ "IOKit" "CoreFoundation" ];
        programs = [ { name = "lspci"; } { name = "setpci"; } ];
      };

      # ZLIB=no keeps the embed patch's FILE* branch wired rather than the zlib
      # one; pcilmr is built but not folded (root/Linux-only). On darwin the
      # SDK-always engine gives the IOKit backend its frameworks (declared
      # above).
      build = pkgs:
        pciTweaks {
          inherit pkgs;
          isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
        }
          pkgs.pkgsStatic.pciutils;

      windowsBuild = pkgs:
        pciTweaks { inherit pkgs; isWindows = true; }
          (ulib.mingwStaticCross pkgs).pciutils;
    };
}
