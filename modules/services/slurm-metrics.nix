{
  config,
  lib,
  ...
}:
let
  cfg = config.services.cluster-slurm-metrics;
in
{
  options.services.cluster-slurm-metrics = {
    enable = lib.mkEnableOption "Slurm 25.11 native OpenMetrics endpoint";
    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 6817;
      description = "slurmctld port; metrics share the RPC socket.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.slurm.extraConfig = lib.mkAfter ''
      MetricsType=metrics/openmetrics
    '';

    networking.firewall.allowedTCPPorts = [ cfg.listenPort ];
  };
}
