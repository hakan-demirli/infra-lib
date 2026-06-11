{
  lib,
  host,
  ...
}:
let
  monitoringEnabled =
    (host.monitoring.enabled or true) && (lib.elem "node" (host.monitoring.exporters or [ "node" ]));
in
{
  config = lib.mkIf monitoringEnabled {
    services.prometheus.exporters.node = {
      enable = true;
      port = 9100;
      enabledCollectors = [
        "systemd"
        "processes"
        "logind"
        "interrupts"
        "ksmd"
        "mountstats"
        "network_route"
        "ntp"
        "tcpstat"
      ];
      disabledCollectors = [
        "wifi"
      ];
      listenAddress = "0.0.0.0";
    };

    networking.firewall.allowedTCPPorts = [ 9100 ];
  };
}
