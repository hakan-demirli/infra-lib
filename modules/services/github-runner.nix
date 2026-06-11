{ config, lib, ... }:
let
  cfg = config.cluster.githubRunner;
in
{
  options.cluster.githubRunner = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable GitHub Actions self-hosted runner.";
    };
    url = lib.mkOption {
      type = lib.types.str;
      example = "https://github.com/your-org";
      description = "GitHub user/organisation URL.";
    };
    name = lib.mkOption {
      type = lib.types.str;
      default = "nixos-runner";
      description = "Runner name (becomes the attr key in services.github-runners).";
    };
    tokenFile = lib.mkOption {
      type = lib.types.path;
      default = "/run/secrets/github-runner-token";
      description = "Path to a file containing the GitHub runner registration token.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.github-runners.${cfg.name} = {
      enable = true;
      inherit (cfg) url tokenFile;
      replace = true;
      extraLabels = [ "nixos" ];
    };

    environment.persistence."/persist".directories = [
      "/var/lib/github-runners"
    ];
  };
}
