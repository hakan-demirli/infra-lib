{
  config,
  lib,
  pkgs,
  cluster,
  ...
}:
let
  inherit (lib) elem;
  cfg = config.services.cluster-victoriametrics;

  exporterPortMap = {
    node = 9100;
    smartctl = 9633;
    ipmi = 9290;
    "lm-sensors" = 9100;
    ceph = 9128;
    slurm = 6817;
    zfs = 9134;
  };

  multiPathExporters = {
    slurm = [
      "/metrics/jobs"
      "/metrics/nodes"
      "/metrics/partitions"
      "/metrics/scheduler"
    ];
  };

  scrapeableHosts = lib.filterAttrs (
    _: h:
    (h.monitoring.enabled or true)
    && !(elem h.state [
      "retired"
      "decommissioned"
    ])
  ) (cluster.hosts or { });

  deployedExporters = lib.unique (
    lib.concatMap (h: h.monitoring.exporters or [ ]) (lib.attrValues scrapeableHosts)
  );

  mkScrapeJob =
    exporter:
    let
      port = exporterPortMap.${exporter};
      targets = lib.mapAttrsToList (id: _: "${id}:${toString port}") (
        lib.filterAttrs (_: h: elem exporter (h.monitoring.exporters or [ ])) scrapeableHosts
      );
      mkOne = path: {
        job_name =
          "fleet-${exporter}"
          + lib.optionalString (path != "/metrics") (
            "-" + lib.replaceStrings [ "/metrics/" "/" ] [ "" "-" ] path
          );
        scrape_interval = "30s";
        metrics_path = path;
        static_configs = [
          {
            inherit targets;
            labels = {
              inherit exporter;
            };
          }
        ];
      };
      paths = multiPathExporters.${exporter} or [ "/metrics" ];
    in
    map mkOne paths;

  extraJobs = lib.concatMap (
    h:
    if (h.monitoring.scrape_targets or [ ]) == [ ] then
      [ ]
    else
      [
        {
          job_name = "extra-${h.id}";
          scrape_interval = "30s";
          static_configs = [
            {
              targets = h.monitoring.scrape_targets;
              labels = {
                host = h.id;
              };
            }
          ];
        }
      ]
  ) (lib.attrValues scrapeableHosts);

  scrapeConfig = {
    global = {
      scrape_interval = "30s";
      external_labels = {
        cluster = "fleet";
      };
    };
    scrape_configs = (lib.concatMap mkScrapeJob deployedExporters) ++ extraJobs;
  };

  scrapeConfigFile = pkgs.writeText "vm-scrape.yml" (builtins.toJSON scrapeConfig);
in
{
  options.services.cluster-victoriametrics = {
    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 8428;
    };
    retentionPeriod = lib.mkOption {
      type = lib.types.str;
      default = "30d";
      description = "How long VictoriaMetrics keeps datapoints. Suffix: h / d / y.";
    };
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/victoriametrics";
    };
  };

  config = {
    services.victoriametrics = {
      enable = true;
      listenAddress = ":${toString cfg.listenPort}";
      inherit (cfg) retentionPeriod;
      extraOptions = [
        "-promscrape.config=${scrapeConfigFile}"
        "-storageDataPath=${cfg.dataDir}"
      ];
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 victoriametrics victoriametrics -"
    ];

    networking.firewall.allowedTCPPorts = [ cfg.listenPort ];
  };
}
