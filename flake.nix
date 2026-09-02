{
  description = "Hytale on aarch64 NixOS (Snapdragon X Elite / X2 Elite): x86_64 launcher and client under a patched FEX, native aarch64 server";

  inputs = {
    # nixpkgs for the emulator recipe and the x86_64 guest userland.
    #
    # The FEX *source* is pinned to the FEX-2608 tag inside the module (the
    # eight patches are written against it), so a nixpkgs that moves to a
    # newer FEX does not change what gets built -- only the build recipe and
    # the guest libraries come from here. The committed flake.lock pins this to
    # a revision known to build; `nix flake update` moves it. To pin it
    # explicitly, replace the branch with a revision:
    #   nixpkgs-fex.url = "github:NixOS/nixpkgs/<rev>";
    # and to reuse a nixpkgs you already track:
    #   inputs.hytale-arm.inputs.nixpkgs-fex.follows = "nixpkgs-unstable";
    nixpkgs-fex.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs-fex, ... }: {
    nixosModules = {
      # Everything: programs.hytale (which enables programs.fex on the patched
      # FEX). Modules are imported by path so importing this together with
      # the individual ones below is harmless.
      default = {
        imports = [ ./modules/hytale.nix ];
        _module.args.hytaleArm = { nixpkgsFex = nixpkgs-fex; };
      };

      # binfmt registrations + hook-capable shim only (programs.fex.*), e.g.
      # for Steam without Hytale. Same argument requirement as above.
      fex = {
        imports = [ ./modules/fex.nix ];
        _module.args.hytaleArm = { nixpkgsFex = nixpkgs-fex; };
      };
    };
  };
}
