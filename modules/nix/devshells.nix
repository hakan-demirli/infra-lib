_: {
  perSystem =
    { pkgs, ... }:
    {
      devShells.default = pkgs.mkShellNoCC {
        packages = with pkgs; [
          nixVersions.latest
          nix-output-monitor
          nixfmt
          statix
          deadnix
          taplo
          jq
          gitMinimal
        ];
      };
    };
}
