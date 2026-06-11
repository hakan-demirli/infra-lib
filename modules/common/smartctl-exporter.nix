{
  lib,
  pkgs,
  host,
  ...
}:
let
  enabled =
    (host.monitoring.enabled or true) && (lib.elem "smartctl" (host.monitoring.exporters or [ ]));
in
{
  config = lib.mkIf enabled {
    services.prometheus.exporters.smartctl = {
      enable = true;
      port = 9633;
      listenAddress = "0.0.0.0";
    };

    environment.systemPackages = [ pkgs.smartmontools ];

    networking.firewall.allowedTCPPorts = [ 9633 ];
  };
}
