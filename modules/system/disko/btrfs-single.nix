{
  lib,
  host ? null,
  ...
}:
let
  d = if host == null then null else (host.disko or null);
  active = d != null && d.managed && d.layout == "btrfs-single";
in
{
  config = lib.mkIf active {
    disko.devices = (import ./btrfs-single/_devices.nix) {
      inherit lib;
      device = d.root_disk;
      swapSize = d.swap_size;
    };
  };
}
