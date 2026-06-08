# pciutils ships separate command-line programs — `lspci` (list PCI devices,
# read-only, no privilege) and `setpci` (read/write PCI config space, root). To
# honour the unpins one-pkg-one-bin rule we post-link them into a single
# multicall binary at $out/bin/pciutils (a busybox-style dispatcher named after
# the package, as the unpins CI resolves result/bin/<package-name>); a bare
# `pciutils` runs lspci (defaultApplet). `lib.withAliases` then embeds `lspci`
# and `setpci` as UNPIN_META aliases so unpin's installer recreates the argv[0]
# shims on PATH.
#
# (pcilmr — the PCIe lane-margining tool — is built by the upstream `all` target
# but NOT folded in: it is root-only, Linux-only, needs system prep, and is
# useless on Windows/macOS. setpci is included but only writes as root on Linux;
# the README documents the per-OS reality.)
#
# Why a post-link route (no source patch): lspci (lspci.o + ls-*.o) and setpci
# (setpci.o) are separate programs that each define `main`, `program_name[]`,
# `verbose` and `pacc`, and BOTH link the shared common.o + the static
# lib/libpci.a. Reuse the proven objcopy rename recipe (cf. flac/libwebp): per
# tool, build ONE redef map (main → <tool>_main, every other strong defined
# global foo → <tool>__foo) from the tool's raw objects and objcopy it onto a
# private copy of each — objcopy rewrites the definition AND every relocation, so
# each tool stays internally consistent and the two `main`s/`program_name`s no
# longer collide. common.o is copied INTO BOTH tool sets (so each gets its own
# renamed copy): common.c's `die` prints `program_name`, so a single shared
# common.o would bind to only one tool's name. libpci.a is self-contained (no
# refs back to tool/common globals) and is linked ONCE, so the binary carries one
# copy of the access library.
#
# The platform link libs come straight out of the generated lib/config.mk's
# WITH_LIBS (linux: none with DNS/ZLIB off; darwin: -lresolv + CoreFoundation /
# IOKit frameworks; windows: -lcfgmgr32 [+ -ladvapi32]), so the exact set the
# build configured is reused verbatim on musl ELF / Mach-O / mingw — no
# hard-coded dependency list to drift. configure writes the resolved libs
# literally (LIBRESOLV/frameworks expanded), so no $(...) survives to resolve.
#
# pci.ids is embedded in the binary (./pciutils-embed-ids.patch + an
# `xxd -i`-generated header baked into libpci before it compiles), so lspci
# resolves vendor/device names with no companion file on every OS. ZLIB=no keeps
# the FILE*/#else names-parse.c branch the embed patch wires; DNS=no (windows)
# drops the POSIX-only names-net.c / names-cache.c paths nixpkgs forces on.
#
# Shared by the native `build` (pkgsStatic) and `windowsBuild`
# (mingwStaticCross) paths; isDarwin/isWindows come from the INPUT derivation's
# stdenv (under windowsBuild `pkgs` is the x86_64-linux root — the cross lives
# inside mingwStaticCross — so `pkgs.stdenv` would wrongly say "not Windows").
{ lib }:
{ pkgs, pciutils }:
let
  isDarwin = pciutils.stdenv.hostPlatform.isDarwin or false;
  isWindows = pciutils.stdenv.hostPlatform.isWindows or false;

  multicall = pciutils.overrideAttrs (old: {
    pname = "pciutils-multi";
    outputs = [ "out" ];

    patches = (old.patches or [ ]) ++ [ ./pciutils-embed-ids.patch ];
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.buildPackages.xxd ];

    # `which` is only used by update-pciids (a runtime script we don't ship); on
    # the mingw cross its which.c calls geteuid() (absent on Windows) and breaks
    # the build, so drop it there.
    buildInputs =
      if isWindows
      then builtins.filter (x: (x.pname or x.name or "") != "which") (old.buildInputs or [ ])
      else (old.buildInputs or [ ]);

    # Bake hwdata's pci.ids into the lib before it compiles.
    postPatch = (old.postPatch or "") + ''
      xxd -i -n embedded_pci_ids \
        ${pkgs.buildPackages.hwdata}/share/hwdata/pci.ids > lib/embedded_pci_ids.h
    '';

    makeFlags = (old.makeFlags or [ ]) ++ [ "ZLIB=no" ]
      ++ lib.optionals isWindows [ "DNS=no" ];

    doCheck = false;
    doInstallCheck = false;

    postBuild = (old.postBuild or "") + ''
      set -e
      mkdir -p mc multicall

      # Tool → its raw objects. common.o is in BOTH sets (private renamed copy
      # per tool). lspci pulls the ls-*.o helpers; setpci is a single object.
      declare -A TOBJ
      TOBJ[lspci]="lspci.o ls-vpd.o ls-caps.o ls-caps-vendor.o ls-ecaps.o ls-kernel.o ls-tree.o ls-map.o common.o"
      TOBJ[setpci]="setpci.o common.o"
      TOOLS="lspci setpci"

      # Mach-O leads C symbols with '_'; detect once from lspci's main object.
      if $NM --defined-only lspci.o 2>/dev/null | awk '$3=="_main"{f=1} END{exit !f}'; then
        up=_
      else
        up=""
      fi

      # Per tool: one redef map (main → <t>_main, other strong defined globals
      # foo → <t>__foo; skip weak/COMDAT W/V and names containing '.'), applied
      # to a private copy of each object so refs follow the rename.
      MCOBJS=""
      for t in $TOOLS; do
        $NM --defined-only ''${TOBJ[$t]} 2>/dev/null \
          | awk -v t="$t" -v up="$up" '
              $2 ~ /^[A-TX-Z]$/ && $2 != "W" && $2 != "V" {
                sym = $3; core = sym
                if (up != "" && index(core, up) == 1) core = substr(core, 2)
                if (index(core, ".") != 0) next
                if (core !~ /^[A-Za-z_][A-Za-z0-9_]*$/) next
                if (core == "main") print sym " " up t "_main"
                else                print sym " " up t "__" core
              }' | sort -u > "mc/$t.redef"
        for o in ''${TOBJ[$t]}; do
          d="mc/$t.$(basename "$o")"
          cp "$o" "$d"
          [ -s "mc/$t.redef" ] && $OBJCOPY --redefine-syms="mc/$t.redef" "$d"
          MCOBJS="$MCOBJS $d"
        done
      done

      # Platform link libs from the generated lib/config.mk: WITH_LIBS (see
      # header comment) plus LIBKMOD_LIBS — on linux the build configures libkmod
      # (ls-kernel.o's "Kernel modules:" lookup), a separate var the Makefile only
      # adds to lspci's LDLIBS. pkg-config under pkgsStatic resolves it to the
      # full static set (-lkmod + its compression deps), written literally.
      MCLIBS=$(sed -n -e 's/^WITH_LIBS[+]\?=//p' -e 's/^LIBKMOD_LIBS=//p' \
        lib/config.mk | tr '\n' ' ')

      # Dispatcher (shared canonical generator — see nix-lib
      # lib.multicallDispatcherC). Applet list from multicall/apps.list ($TOOLS);
      # a bare/unknown invocation runs lspci (defaultApplet) so the `pciutils
      # --version` smoke reaches lspci_main and a renamed copy still dispatches.
      printf '%s\n' $TOOLS > multicall/apps.list
${lib.multicallDispatcherC { name = "pciutils"; defaultApplet = "lspci"; }}
      $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

      # Final link: renamed tool objects + dispatcher + libpci.a (once) + the
      # platform libs. GNU ld groups the archive to absorb back-refs; ld64
      # (darwin) re-scans on its own and rejects --start-group. mingw: -static so
      # this manual link (which bypasses mingwStaticCross's -static) keeps only
      # real Windows system DLLs.
      if ${if isDarwin then "true" else "false"}; then
        GO=""; GC=""
      else
        GO="-Wl,--start-group"; GC="-Wl,--end-group"
      fi
      MCF=""
      ${lib.optionalString isWindows ''MCF="-static"''}
      $CC -O2 \
        $MCOBJS multicall/dispatcher.o \
        $GO lib/libpci.a $GC $MCLIBS $MCF \
        -o mc/pciutils
      [ -f mc/pciutils ] || mv mc/pciutils.exe mc/pciutils
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin" "$out/share/man/man8"
      # Canonical binary named after the package (pciutils) — a busybox-style
      # dispatcher. `lspci`/`setpci` are NOT shipped as files: they are declared
      # as explicit lib.withAliases entries (embedded in the binary), and unpin
      # recreates them as argv[0] shims on PATH at install. share/pci.ids is NOT
      # installed: it's embedded.
      install -m755 mc/pciutils "$out/bin/pciutils"
      # Both man pages are generated by the upstream `all` target into the build
      # root; ship lspci.8 + setpci.8 (the two applets/aliases).
      for m in lspci setpci; do
        [ -f "$m.8" ] && cp "$m.8" "$out/share/man/man8/$m.8"
      done
      runHook postInstall
    '';

    # The base nixpkgs pciutils carries a postInstall that `rm`s artifacts of the
    # normal `make install` (sbin/update-pciids, its man page); our custom
    # installPhase never creates them, so clear it or `runHook postInstall` dies.
    postInstall = "";
  });

  aliased = lib.withAliases pkgs
    {
      primary = "pciutils";
      aliases = [ "lspci" "setpci" ];
    }
    multicall;
in
if isWindows
then aliased.overrideAttrs (o: {
  postFixup = (o.postFixup or "") + ''
    [ -f "$out/bin/pciutils" ] && mv "$out/bin/pciutils" "$out/bin/pciutils.exe"
  '';
})
else aliased
