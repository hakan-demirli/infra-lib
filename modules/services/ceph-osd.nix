{
  lib,
  host ? null,
  ...
}:
let
  hostCeph = if host == null then null else (host.ceph or null);
  diskEntries = if hostCeph == null then [ ] else (hostCeph.osd_disks or [ ]);
  dataDaemons = map (e: e.name) (lib.filter (e: e.role == "data") diskEntries);
  active = host != null && dataDaemons != [ ];
in
{
  imports = [ ./ceph-common.nix ];

  config = lib.mkIf active {
    services.ceph.osd = {
      enable = true;
      daemons = dataDaemons;
    };

    networking.firewall.allowedTCPPortRanges = [
      {
        from = 6800;
        to = 7300;
      }
    ];

    environment.systemPackages = [ ];
    boot.kernelModules = [
      "xfs"
      "btrfs"
    ];
  };
}
