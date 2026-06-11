{
  lib,
  pkgs,
  host ? null,
  ...
}:
let
  impermanenceEnabled = host != null && (host.impermanence.enable or false);
in
{
  programs.singularity = {
    enable = true;
    package = pkgs.apptainer;
    enableFakeroot = true;
  };

  users.groups.apptainer = { };

  environment.persistence = lib.mkIf impermanenceEnabled {
    "/persist/system" = {
      directories = [
        "/var/lib/apptainer"
      ];
    };
  };
}
