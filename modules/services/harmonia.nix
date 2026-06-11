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
        type = lib.types.str;
        default = "nix-serve-key";
      };

      hostLocalPath = lib.mkOption {
        type = lib.types.path;
      };
    };
  };

  config =
    let
      useSops = cfg.signKey.source == "sops";
      keyPath =
        if useSops then config.sops.secrets.${cfg.signKey.sopsKeyName}.path else cfg.signKey.hostLocalPath;
    in
    lib.mkMerge [
      {
        services.harmonia.cache = {
          enable = true;
          signKeyPaths = [ keyPath ];
          settings.bind = "[::]:5101";
        };

        networking.firewall.allowedTCPPorts = [ 5101 ];
      }

      (lib.mkIf useSops {
        sops.secrets.${cfg.signKey.sopsKeyName} = { };
      })
    ];
}
