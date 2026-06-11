{
  config,
  lib,
  ...
}:
let
  cfg = config.services.cluster-harmonia;
in
{
  options.services.cluster-harmonia = {
    signKey = {
      source = lib.mkOption {
        type = lib.types.enum [
          "sops"
          "host-local"
        ];
      };

      sopsKeyName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };

      hostLocalPath = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
      };
    };
  };

  config =
    let
      useSops = cfg.signKey.source == "sops";
      sopsKeyName =
        if cfg.signKey.sopsKeyName == null then "__MISSING_SOPS_KEY__" else cfg.signKey.sopsKeyName;
      keyPath =
        if useSops then
          config.sops.secrets.${sopsKeyName}.path
        else if cfg.signKey.hostLocalPath == null then
          "/dev/null"
        else
          cfg.signKey.hostLocalPath;
    in
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = !useSops || (cfg.signKey.sopsKeyName != null && cfg.signKey.hostLocalPath == null);
            message = "cluster-harmonia signKey.source=sops requires only signKey.sopsKeyName.";
          }
          {
            assertion = useSops || (cfg.signKey.hostLocalPath != null && cfg.signKey.sopsKeyName == null);
            message = "cluster-harmonia signKey.source=host-local requires only signKey.hostLocalPath.";
          }
        ];

        services.harmonia.cache = {
          enable = true;
          signKeyPaths = [ keyPath ];
          settings.bind = "[::]:5101";
        };

        networking.firewall.allowedTCPPorts = [ 5101 ];
      }

      (lib.mkIf useSops {
        sops.secrets.${sopsKeyName} = { };
      })
    ];
}
