{
  config,
  lib,
  self,
  ...
}:
let
  cfg = config.services.cluster-vmalert;

  ruleFiles =
    if !builtins.pathExists cfg.ruleDir then
      [ ]
    else
      lib.mapAttrsToList (name: _: cfg.ruleDir + "/${name}") (
        lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".yaml" n) (builtins.readDir cfg.ruleDir)
      );
in
{
  options.services.cluster-vmalert = {
    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 8880;
      description = "vmalert HTTP API port (UI + /api/v1/alerts).";
    };
    datasourceUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8428";
      description = "VictoriaMetrics (Prometheus-compatible) datasource.";
    };
    notifierUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:9093";
      description = "alertmanager URL to notify on firing alerts.";
    };
    ruleDir = lib.mkOption {
      type = lib.types.path;
      default = self + "/inventory/alerts";
      defaultText = lib.literalExpression ''self + "/inventory/alerts"'';
      description = "Directory containing alert rule YAML files.";
    };
    evaluationInterval = lib.mkOption {
      type = lib.types.str;
      default = "15s";
    };
  };

  config = {
    services.vmalert.instances.default = {
      enable = true;
      settings = {
        "datasource.url" = cfg.datasourceUrl;
        "notifier.url" = [ cfg.notifierUrl ];
        "rule" = ruleFiles;
        "evaluationInterval" = cfg.evaluationInterval;
        "httpListenAddr" = ":${toString cfg.listenPort}";
      };
    };

    networking.firewall.allowedTCPPorts = [ cfg.listenPort ];
  };
}
