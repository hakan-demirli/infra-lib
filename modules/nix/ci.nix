{ inputs, ... }:
let
  # nixbot runs effects on its own host, vps-oracle-0.
  pkgs = inputs.nixpkgs.legacyPackages.aarch64-linux;
in
{
  flake.herculesCI =
    { primaryRepo, ... }:
    inputs.self.lib.mkForgeFlow {
      inherit pkgs primaryRepo;
      bot = {
        name = "hakan-demirli-infra-dependencies[bot]";
        email = "328803426+hakan-demirli-infra-dependencies[bot]@users.noreply.github.com";
      };
      # Before the dotfiles update at 07:17, which picks up this repository's main.
      update = {
        hour = 4;
        minute = 17;
      };
    };
}
