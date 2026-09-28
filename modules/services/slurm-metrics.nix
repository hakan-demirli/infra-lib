{
  config,
  lib,
  ...
}:
let
  cfg = config.services.cluster-slurm-metrics;
  ports = import ../lib/slurm-ports.nix;
in
{
  options.services.cluster-slurm-metrics = {
    enable = lib.mkEnableOption "Slurm 25.11 native OpenMetrics endpoint";
    listenPort = lib.mkOption {
      type = lib.types.port;
      default = ports.controller;
      description = "slurmctld port; metrics share the RPC socket.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.enable || cfg.listenPort == ports.controller;
          message = "services.cluster-slurm-metrics.listenPort requires enable=true.";
        }
      ];
    }

    (lib.mkIf cfg.enable {
      services.slurm.extraConfig = lib.mkAfter ''
        MetricsType=metrics/openmetrics
      '';

      networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [
        cfg.listenPort
      ];
    })
  ];
}
