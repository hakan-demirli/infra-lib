{
  config,
  lib,
  host ? null,
  ...
}:
let
  cfg = config.services.cluster-victorialogs;
  impermanenceEnabled = host != null && (host.impermanence.enable or false);
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

    users.users.victorialogs = {
      isSystemUser = true;
      group = "victorialogs";
    };
    users.groups.victorialogs = { };

    systemd.services.victorialogs.serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "victorialogs";
      Group = "victorialogs";
    };

    environment.persistence = lib.mkIf impermanenceEnabled {
      "/persist/system".directories = [
        {
          directory = "/var/lib/victorialogs";
          user = "victorialogs";
          group = "victorialogs";
          mode = "0700";
        }
      ];
    };

    networking.firewall.allowedTCPPorts = [ cfg.listenPort ];
  };
}
