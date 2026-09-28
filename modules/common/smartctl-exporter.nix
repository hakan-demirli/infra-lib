{
  lib,
  pkgs,
  host,
  ...
}:
let
  ports = import ../lib/exporter-ports.nix;
  enabled =
    (host.monitoring.enabled or true) && (lib.elem "smartctl" (host.monitoring.exporters or [ ]));
in
{
  imports = [ ./tailnet-only-ports.nix ];

  config = lib.mkIf enabled {
    services.prometheus.exporters.smartctl = {
      enable = true;
      port = ports.smartctl;
      listenAddress = "0.0.0.0";
    };

    environment.systemPackages = [ pkgs.smartmontools ];

    cluster.firewall.tailnetOnlyTCPPorts = [ ports.smartctl ];
  };
}
