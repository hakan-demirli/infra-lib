{
  config,
  lib,
  ...
}:
let
  cfg = config.services.cluster-victorialogs;
in
{
  options.services.cluster-victorialogs = {
    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 9428;
    };
    retentionPeriod = lib.mkOption {
      type = lib.types.str;
      default = "30d";
      description = "How long VictoriaLogs keeps log entries. Suffix: h/d/y.";
    };
  };

  config = {
    services.victorialogs = {
      enable = true;
      listenAddress = ":${toString cfg.listenPort}";
      extraOptions = [
        "-retentionPeriod=${cfg.retentionPeriod}"
      ];
    };

    networking.firewall.allowedTCPPorts = [ cfg.listenPort ];
  };
}
