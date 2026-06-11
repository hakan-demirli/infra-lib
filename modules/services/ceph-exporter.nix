{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.cluster-ceph-exporter;
in
{
  options.services.cluster-ceph-exporter = {
    enable = lib.mkEnableOption "ceph-mgr prometheus module wiring";
    mgrInstance = lib.mkOption {
      type = lib.types.str;
      description = "Local ceph-mgr instance name (matches ceph-mgr-<name>.service).";
    };
    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 9128;
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services."ceph-mgr-${cfg.mgrInstance}".environment.PYTHONPATH =
      lib.makeSearchPath "lib/python3.12/site-packages"
        [
          pkgs.python312Packages.cherrypy
          pkgs.python312Packages.pyyaml
          pkgs.python312Packages.more-itertools
          pkgs.python312Packages.jaraco-collections
          pkgs.python312Packages.jaraco-functools
          pkgs.python312Packages.zc-lockfile
          pkgs.python312Packages.cheroot
          pkgs.python312Packages.portend
          pkgs.python312Packages.tempora
          pkgs.python312Packages.pytz
          pkgs.python312Packages.jaraco-text
          pkgs.python312Packages.jaraco-context
        ];

    systemd.services."ceph-mgr-prometheus-enable" = {
      description = "Enable ceph-mgr prometheus module and pin port";
      after = [ "ceph-mgr-${cfg.mgrInstance}.service" ];
      path = [ pkgs.ceph ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        for i in $(seq 1 120); do
          if ceph mgr module ls 2>/dev/null | grep -q '"prometheus"'; then
            break
          fi
          sleep 1
        done
        ceph mgr module enable prometheus
        ceph config set mgr mgr/prometheus/server_port ${toString cfg.listenPort}
        ceph config set mgr mgr/prometheus/server_addr 0.0.0.0
        ceph mgr module disable prometheus
        ceph mgr module enable prometheus
        for i in $(seq 1 60); do
          if ${pkgs.iproute2}/bin/ss -ltn | grep -q ":${toString cfg.listenPort} "; then
            exit 0
          fi
          sleep 1
        done
        echo "WARN: prometheus module enabled but :${toString cfg.listenPort} not listening" >&2
      '';
    };

    networking.firewall.allowedTCPPorts = [ cfg.listenPort ];
  };
}
