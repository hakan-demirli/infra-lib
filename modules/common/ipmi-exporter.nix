{
  lib,
  pkgs,
  host,
  ...
}:
let
  ports = import ../lib/exporter-ports.nix;
  enabled = (host.monitoring.enabled or true) && (lib.elem "ipmi" (host.monitoring.exporters or [ ]));
in
{
  imports = [ ./tailnet-only-ports.nix ];

  config = lib.mkIf enabled {
    services.prometheus.exporters.ipmi = {
      enable = true;
      port = ports.ipmi;
      listenAddress = "0.0.0.0";
    };

    environment.systemPackages = [
      pkgs.freeipmi
      pkgs.ipmitool
    ];

    boot.kernelModules = [
      "ipmi_devintf"
      "ipmi_si"
    ];

    cluster.firewall.tailnetOnlyTCPPorts = [ ports.ipmi ];
  };
}
