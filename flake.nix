{
  description = "Oka deployment bundle for Taina";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05-small";
    taina = {
      url = "github:taina-labs/taina/v0.6.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, taina, ... }:
    let
      systems = nixpkgs.lib.systems.flakeExposed;
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in
    {
      formatter = forAllSystems (pkgs: pkgs.nixpkgs-fmt);
      nixosModules = {
        taina = taina.nixosModules.taina;
        default = taina.nixosModules.default;
      };
    };
}
