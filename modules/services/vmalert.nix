{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  cfg = config.services.cluster-vmalert;

  ruleFiles =
    if !builtins.pathExists cfg.ruleDir then
      throw ''
        services.cluster-vmalert: ruleDir '${toString cfg.ruleDir}' does not exist.
        vmalert is enabled but has nowhere to load alert rules from. Either:
          - create the directory (even empty is fine, it means "explicitly no rules"), or
          - set services.cluster-vmalert.ruleDir to a directory you do maintain.
      ''
    else
      let
        entries = builtins.readDir cfg.ruleDir;
        nixEntries = lib.filterAttrs (
          n: t: t == "regular" && lib.hasSuffix ".nix" n && !lib.hasPrefix "_" n
        ) entries;
        renderOne =
          name: _:
          let
            basename = lib.removeSuffix ".nix" name;
            data = import (cfg.ruleDir + "/${name}");
          in
          pkgs.writeText "vmalert-${basename}.yaml" (builtins.toJSON data);
      in
      lib.mapAttrsToList renderOne nixEntries;
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
      description = ''
        Directory containing alert-rule Nix files. Each `*.nix` file
        returns an attrset in Prometheus / vmalert rule format
        (`{ groups = [ { name; interval; rules = [ ... ]; } ]; }`).
        Files whose basename starts with `_` are skipped.
        Each file is serialized to a YAML equivalent at build time
        via toJSON (YAML is a superset of JSON) and passed to vmalert.
      '';
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
