{ pkgs, ... }:
{
  programs.singularity = {
    enable = true;
    package = pkgs.apptainer;
    enableFakeroot = true;
  };

  users.groups.apptainer = { };

  environment.persistence."/persist/system" = {
    directories = [
      "/var/lib/apptainer"
    ];
  };
}
