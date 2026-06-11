{
  lib,
  pkgs,
  host,
  ...
}:
let
  enabled = (host.monitoring.enabled or true) && (lib.elem "ipmi" (host.monitoring.exporters or [ ]));
in
{
  config = lib.mkIf enabled {
    services.prometheus.exporters.ipmi = {
      enable = true;
      port = 9290;
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

    networking.firewall.allowedTCPPorts = [ 9290 ];
  };
}
