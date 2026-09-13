{
  config,
  lib,
  host ? null,
  ...
}:
let
  registration = if host == null then "nvram" else (host.boot.efi_registration or "nvram");
  grubEfi = config.boot.loader.grub.enable && config.boot.loader.grub.efiSupport;
in
{
  boot.loader = {
    systemd-boot.enable = lib.mkDefault true;
    efi.canTouchEfiVariables = lib.mkDefault (registration == "nvram");
    grub.efiInstallAsRemovable = lib.mkIf grubEfi (lib.mkDefault (registration == "fallback"));
  };
}
