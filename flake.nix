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

  outputs = { self, ... }@inputs:
    let
      # The modules take `inputs` so they can import nixpkgs-fex for the
      # emulator packages and the x86_64 guest userland.
      mkModule = path: args: import path (args // { inherit inputs; });
    in
    {
      nixosModules = {
        # binfmt registrations + hook-capable shim (required by the Hytale module)
        fex = mkModule ./modules/fex.nix;
        # launcher, client, server, desktop entry
        hytale = mkModule ./modules/hytale.nix;
        default = {
          imports = [ self.nixosModules.fex self.nixosModules.hytale ];
        };
      };
    };
}
