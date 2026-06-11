{
  lib,
  host ? null,
  ...
}:
let
  active = host != null;
in
{
  imports = [ ./ceph-common.nix ];

  config = lib.mkIf active {
    services.ceph.mds = {
      enable = true;
      daemons = [ host.id ];
    };

    networking.firewall.allowedTCPPortRanges = [
      {
        from = 6800;
        to = 7300;
      }
    ];
  };
}
