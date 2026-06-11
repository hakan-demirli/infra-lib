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
    services.ceph.mgr = {
      enable = true;
      daemons = [ host.id ];
    };

    networking.firewall.allowedTCPPorts = [
      9283
      9128
    ];
  };
}
