{ lib, pkgs, ... }:
{
  networking.networkmanager.enable = lib.mkDefault true;
  time.timeZone = lib.mkDefault "Europe/Zurich";

  systemd.services.NetworkManager-wait-online.enable = false;
  systemd.network.wait-online.enable = false;

  environment.systemPackages = with pkgs; [
    kitty
    foot
    xterm
    tofi
  ];

  documentation = {
    enable = lib.mkOverride 900 true;
    nixos.enable = lib.mkOverride 900 true;
  };

  hardware.keyboard.qmk.enable = lib.mkDefault true;
}
