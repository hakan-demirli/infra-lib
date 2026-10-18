{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.cluster-ceph-exporter;
  ports = import ../lib/exporter-ports.nix;
in
{
  options.services.cluster-ceph-exporter = {
    enable = lib.mkEnableOption "ceph-mgr prometheus module wiring";
    mgrInstance = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Local ceph-mgr instance name (matches ceph-mgr-<name>.service).";
    };
    listenPort = lib.mkOption {
      type = lib.types.port;
      default = ports.ceph;
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.enable || (cfg.mgrInstance == "" && cfg.listenPort == ports.ceph);
          message = "services.cluster-ceph-exporter payload is configured while enable=false.";
        }
        {
          assertion = !cfg.enable || cfg.mgrInstance != "";
          message = "services.cluster-ceph-exporter.mgrInstance must be set when enable=true.";
        }
      ];
    }

    (lib.mkIf cfg.enable {
      systemd.services."ceph-mgr-prometheus-enable" = {
        description = "Enable ceph-mgr prometheus module and pin port";
        after = [ "ceph-mgr-${cfg.mgrInstance}.service" ];
        path = [
          pkgs.ceph
          pkgs.iproute2
          pkgs.jq
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail

          wait_until() {
            local seconds=$1
            shift
            for _ in $(seq "$seconds"); do
              if "$@"; then
                return 0
              fi
              sleep 1
            done
            return 1
          }

          prometheus_available() {
            ceph mgr module ls --format json \
              | jq -e '(.enabled_modules | index("prometheus")) or any(.disabled_modules[]; .name == "prometheus")' > /dev/null
          }

          prometheus_listening() {
            ss -Htln "sport = :${toString cfg.listenPort}" | grep -q .
          }

          if ! wait_until 120 prometheus_available; then
            echo "ceph-mgr did not report the prometheus module within 120 seconds" >&2
            exit 1
          fi

          ceph config set mgr mgr/prometheus/server_addr 0.0.0.0
          ceph config set mgr mgr/prometheus/server_port ${toString cfg.listenPort}
          ceph mgr module enable prometheus

          if ! wait_until 60 prometheus_listening; then
            echo "ceph-mgr prometheus module is enabled but :${toString cfg.listenPort} is not listening" >&2
            exit 1
          fi
        '';
      };

      networking.firewall.allowedTCPPorts = [ cfg.listenPort ];
    })
  ];
}
