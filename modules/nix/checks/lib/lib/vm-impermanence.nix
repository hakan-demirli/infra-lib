{ inputs }:
{ lib, ... }:
{
  imports = [ inputs.impermanence.nixosModules.impermanence ];

  virtualisation.fileSystems."/persist/system" = {
    fsType = lib.mkForce "tmpfs";
    device = lib.mkForce "none";
    neededForBoot = true;
  };

  environment.persistence."/persist/system" = {
    hideMounts = true;
    directories = [
      "/var/lib/nixos"
    ];
  };
}
