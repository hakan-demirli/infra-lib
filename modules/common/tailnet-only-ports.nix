{
  config,
  lib,
  ...
}:
let
  cfg = config.cluster.firewall;
  inherit (config.networking) firewall;
  tailnetInterface = config.services.tailscale.interfaceName;

  opens =
    rules: port:
    lib.elem port rules.allowedTCPPorts
    || lib.any (range: range.from <= port && port <= range.to) rules.allowedTCPPortRanges;
  nonTailnetRules = [
    firewall
  ]
  ++ lib.attrValues (removeAttrs firewall.interfaces [ tailnetInterface ]);
  exposedPorts = lib.filter (
    port: lib.any (rules: opens rules port) nonTailnetRules
  ) cfg.tailnetOnlyTCPPorts;
in
{
  options.cluster.firewall.tailnetOnlyTCPPorts = lib.mkOption {
    type = lib.types.listOf lib.types.port;
    default = [ ];
    description = "TCP ports that only the tailnet interface opens. Evaluation fails when another firewall rule opens one of them.";
  };

  config = {
    assertions = [
      {
        assertion = exposedPorts == [ ];
        message = "cluster.firewall.tailnetOnlyTCPPorts ${
          lib.concatMapStringsSep "," toString exposedPorts
        } must stay closed outside ${tailnetInterface}, but another networking.firewall rule opens them.";
      }
    ];

    networking.firewall.interfaces.${tailnetInterface}.allowedTCPPorts = cfg.tailnetOnlyTCPPorts;
  };
}
