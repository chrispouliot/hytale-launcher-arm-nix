# FEX for the whole system: binfmt_misc registrations for x86_64 and i386 ELF
# binaries through a small shim, optional global RootFS config for users.
# `hytaleArm` is provided by the flake (nixosModules.default sets
# _module.args.hytaleArm = { nixpkgsFex = <nixpkgs with fex 2608>; }).
{ hytaleArm, config, pkgs, lib, ... }:

let
  cfg = config.programs.fex;

  fexPkgs = import hytaleArm.nixpkgsFex { system = pkgs.stdenv.hostPlatform.system; };
  fex = cfg.package;

  fexConfig = pkgs.writeText "fex-config.json" (builtins.toJSON {
    Config = { RootFS = "${cfg.rootfs}"; };
    ThunksDB = { };
  });

  fexCompat = pkgs.symlinkJoin {
    name = "fex-with-interpreter-alias";
    paths = [ fex ];
    postBuild = ''ln -s ${fex}/bin/FEX "$out/bin/FEXInterpreter"'';
  };

  # binfmt_misc interpreter shim. With flag O the kernel hands the binary over
  # as AT_EXECFD; that auxv entry does not survive another execv, so it is
  # re-exported as FEX_EXECVEFD, which FEX reads at startup and treats exactly
  # like a binfmt launch (argv[0] preservation included). If the calling
  # process has FEX_BINFMT_HOOK set (ignored under AT_SECURE), the hook gets
  # the exec and decides what runs -- that is how the Hytale module puts the
  # client on its own emulator setup. Cost for everything else: one execv.
  fexBinfmt = pkgs.runCommandCC "fex-binfmt" { } ''
    mkdir -p $out/bin
    $CC -O2 -Wall -o $out/bin/fex-binfmt -x c - <<'EOC'
    #define _GNU_SOURCE
    #include <stdio.h>
    #include <stdlib.h>
    #include <unistd.h>
    #include <sys/auxv.h>
    int main(int argc, char **argv) {
      unsigned long fd = getauxval(AT_EXECFD);
      if (fd) { char b[24]; snprintf(b, sizeof b, "%lu", fd); setenv("FEX_EXECVEFD", b, 1); }
      const char *hook = secure_getenv("FEX_BINFMT_HOOK");
      if (hook && *hook) execv(hook, argv);
      execv("${fex}/bin/FEX", argv);
      perror("fex-binfmt");
      return 127;
    }
    EOC
  '';

  fexInterp = {
    interpreter = "${fexBinfmt}/bin/fex-binfmt";
    preserveArgvZero = true;
    openBinary = true;
    matchCredentials = true;
    fixBinary = true;
    wrapInterpreterInShell = false;
  };
in
{
  options.programs.fex = {
    enable = lib.mkEnableOption "FEX binfmt registrations (FEX-x86_64, FEX-x86) with the hook-capable shim";

    package = lib.mkOption {
      type = lib.types.package;
      default = fexPkgs.fex;
      defaultText = lib.literalExpression "nixpkgs-fex.fex";
      description = ''
        The FEX build used by the binfmt shim's default path (and as
        `FEXInterpreter` on PATH), i.e. by x86 programs outside Hytale's
        process tree. Hytale routes its own tree to its patched build through
        the shim's hook regardless of this setting; opt other programs into
        that build with `programs.fex.package = config.programs.hytale.fexPackage`.
      '';
    };

    rootfs = lib.mkOption {
      type = lib.types.nullOr (lib.types.either lib.types.path lib.types.package);
      default = null;
      example = lib.literalExpression ''
        pkgs.fetchurl {
          name = "Ubuntu_24_04.sqsh";
          url = "https://rootfs.fex-emu.gg/Ubuntu_24_04/2026-08-11/Ubuntu_24_04.sqsh";
          hash = "sha256-KFSwbT/xuPblJhNb+23Vt7MKs6tz55rpM6PZ/tlZoXg=";
        }
      '';
      description = ''
        Global FEX RootFS (squashfs image or directory) for general x86_64
        programs such as Steam. Written read-only to ~/.fex-emu/Config.json for
        each user in `users`. Hytale never uses this: it runs with its own
        config directory and its own loader-only RootFS.
      '';
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Users whose ~/.fex-emu/Config.json points at `rootfs`.";
    };

    binBash = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Symlink /bin/bash (x86 scripts such as Steam's assume it exists).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      fexCompat
      pkgs.squashfuse
    ];

    systemd.tmpfiles.rules = lib.mkIf cfg.binBash [
      "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash"
    ];

    # ~/.fex-emu/Config.json -> read-only Nix file; FEXConfig cannot mutate it.
    systemd.user.tmpfiles.users = lib.mkIf (cfg.rootfs != null) (lib.genAttrs cfg.users (_: {
      rules = [
        "d %h/.fex-emu 0700 - - -"
        "L+ %h/.fex-emu/Config.json - - - - ${fexConfig}"
      ];
    }));

    # The names are load-bearing. When FEX is not launched by the kernel
    # directly it probes /proc/sys/fs/binfmt_misc/FEX-x86_64 and FEX-x86 to
    # decide it may leave child execve() to the kernel (ExecveHandler,
    # IsBinfmtCompatible); otherwise it re-launches itself and bypasses the
    # shim. boot.binfmt.emulatedSystems forces the name x86_64-linux, so do not
    # combine the two -- re-add nix.settings.extra-platforms = [ "x86_64-linux" ]
    # yourself if you relied on it.
    boot.binfmt.registrations = {
      FEX-x86_64 = fexInterp // {
        magicOrExtension = ''\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00'';
        mask = ''\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'';
      };

      # EM_386 (machine 3), not NixOS's i686-linux EM_486 magic.
      FEX-x86 = fexInterp // {
        magicOrExtension = ''\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x03\x00'';
        mask = ''\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'';
      };
    };
  };
}
