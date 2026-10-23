{
  description = "oka: the Taina box, the operator CLI and the NixOS module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # The release the module runs and the CLI operates. taina owns its build.
    # Pinned to a release tag, not main: the module and CLI target a shipped
    # taina. `.github/workflows/update-taina.yml` bumps this tag and re-locks.
    taina = {
      url = "github:taina-labs/taina/v0.5.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Pinned Zig toolchain: nixpkgs' zig moves with the channel and lags the
    # CLI's minimum_zig_version.
    zig-overlay.url = "github:mitchellh/zig-overlay";
  };

  outputs = {
    self,
    nixpkgs,
    taina,
    zig-overlay,
  }: let
    inherit (nixpkgs.lib) genAttrs;
    inherit (nixpkgs.lib.systems) flakeExposed;

    forAllSystems = f:
      genAttrs flakeExposed (system: f (import nixpkgs {inherit system;}));

    # The zig the CLI is built with. Bump it when cli/.zig-version moves.
    zig = system: zig-overlay.packages.${system}."0.17.0";
  in {
    # The operator CLI, `taina`. nix build .#taina-cli produces bin/taina.
    packages = forAllSystems (pkgs: {
      taina-cli = pkgs.callPackage ./nix/cli.nix {
        zig = zig pkgs.stdenv.hostPlatform.system;
      };
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.taina-cli;
    });

    # Runs taina as a plain systemd service from the Nix-built release, and puts
    # the CLI on PATH. No container runtime and no container image: on NixOS the
    # update is `nixos-rebuild switch`. See nix/module.nix.
    nixosModules = {
      taina = {
        pkgs,
        lib,
        ...
      }: {
        imports = [./nix/module.nix];
        services.taina = {
          package = lib.mkDefault taina.packages.${pkgs.stdenv.hostPlatform.system}.taina;
          cli = {
            enable = lib.mkDefault true;
            package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.taina-cli;
          };
        };
      };
      default = self.nixosModules.taina;
    };

    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        name = "oka-dev";
        packages = [
          (zig pkgs.stdenv.hostPlatform.system)
          pkgs.just
        ];
      };
    });
  };
}
