{
  lib,
  host ? null,
  ...
}:
let
  d = if host == null then null else (host.disko or null);
  active = d != null && d.managed && d.layout == "zfs-single";
in
{
  config = lib.mkIf active {
    disko.devices = (import ./zfs-single/_devices.nix) {
      inherit lib;
      device = d.root_disk;
      swapSize = d.swap_size;
    };

    networking.hostId = lib.substring 0 8 (builtins.hashString "md5" host.id);

    boot.supportedFilesystems.zfs = lib.mkDefault true;
    boot.zfs.forceImportRoot = lib.mkDefault false;
  };
}
