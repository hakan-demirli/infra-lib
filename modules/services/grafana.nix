{
  config,
  lib,
  ...
}:
let
  cfg = config.services.cluster-grafana;
  vm = config.services.cluster-victoriametrics;
in
{
  options.services.cluster-grafana = {
    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 3000;
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "grafana.cluster.local";
    };
    adminPassword = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = ''
        Initial admin password. In production this should be set from a
        sops secret (see modules/services/sops.nix); the default here
        exists only to make the test happy.
      '';
    };
    anonymousViewer = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Allow read-only anonymous viewing. Useful in the test scenario
        (we curl Grafana without auth) and on tightly-controlled tailnets.
      '';
    };
  };

  config = {
    services.grafana = {
      enable = true;
      dataDir = "/var/lib/grafana";

      settings = {
        server = {
          http_addr = "0.0.0.0";
          http_port = cfg.listenPort;
          inherit (cfg) domain;
        };
        analytics.reporting_enabled = false;
        security = {
          admin_user = "admin";
          admin_password = cfg.adminPassword;
          secret_key = "CHANGEME-IN-PROD-via-sops-secret_key_file";
        };
        "auth.anonymous" = lib.mkIf cfg.anonymousViewer {
          enabled = true;
          org_role = "Viewer";
        };
      };

      provision = {
        enable = true;
        datasources.settings = {
          apiVersion = 1;
          datasources = [
            {
              name = "VictoriaMetrics";
              type = "prometheus";
              access = "proxy";
              url = "http://127.0.0.1:${toString vm.listenPort}";
              isDefault = true;
              editable = false;
            }
          ];
        };
      };
    };

    networking.firewall.allowedTCPPorts = [ cfg.listenPort ];
  };
}
