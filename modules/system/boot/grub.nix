{ lib, ... }:
{
  imports = [ ./default.nix ];

  boot.loader = {
    systemd-boot.enable = false;
    grub = {
      enable = lib.mkDefault true;
      efiSupport = true;
      device = "nodev";
      useOSProber = true;
      default = "saved";
      configurationLimit = 6;
    };
  };
}
