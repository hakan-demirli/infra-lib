{
  config,
  lib,
  ...
}:
let
  cfg = config.services.cluster-alertmanager;
in
{
  options.services.cluster-alertmanager = {
    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 9093;
    };
    webhookUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8111/alerts";
      description = "Webhook receiver URL for forwarded alerts.";
    };
    groupWait = lib.mkOption {
      type = lib.types.str;
      default = "10s";
    };
    groupInterval = lib.mkOption {
      type = lib.types.str;
      default = "30s";
    };
    repeatInterval = lib.mkOption {
      type = lib.types.str;
      default = "1m";
    };
    sendResolved = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
  };

  config = {
    services.prometheus.alertmanager = {
      enable = true;
      port = cfg.listenPort;
      openFirewall = true;
      configuration = {
        global = { };
        route = {
          receiver = "ntfy";
          group_by = [ "alertname" ];
          group_wait = cfg.groupWait;
          group_interval = cfg.groupInterval;
          repeat_interval = cfg.repeatInterval;
        };
        receivers = [
          {
            name = "ntfy";
            webhook_configs = [
              {
                url = cfg.webhookUrl;
                send_resolved = cfg.sendResolved;
              }
            ];
          }
        ];
      };
    };

    users.users.alertmanager = {
      isSystemUser = true;
      group = "alertmanager";
    };
    users.groups.alertmanager = { };

    systemd.services.alertmanager.serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "alertmanager";
      Group = "alertmanager";
    };

    environment.persistence."/persist/system".directories = [
      {
        directory = "/var/lib/alertmanager";
        user = "alertmanager";
        group = "alertmanager";
        mode = "0700";
      }
    ];
  };
}
