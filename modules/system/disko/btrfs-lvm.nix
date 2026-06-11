{
  lib,
  host ? null,
  ...
}:
let
  d = if host == null then null else (host.disko or null);
  active = d != null && d.managed && d.layout == "btrfs-lvm";

  homeMode = if host == null then "persist-all" else (host.impermanence.home_mode or "persist-all");
  separateHome = homeMode != "selective";
in
{
  config = lib.mkIf active {
    disko.devices = (import ./btrfs-lvm/_devices.nix) {
      inherit lib separateHome;
      device = d.root_disk;
      swapSize = d.swap_size;
      additionalDisks = [ ];
    };
  };
}
