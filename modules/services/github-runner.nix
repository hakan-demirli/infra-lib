{
  config,
  lib,
  host ? null,
  ...
}:
let
  cfg = config.cluster.githubRunner;
  impermanenceEnabled = host != null && (host.impermanence.enable or false);
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
      default = "";
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

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion =
            cfg.enable
            || (
              cfg.url == "" && cfg.name == "nixos-runner" && cfg.tokenFile == "/run/secrets/github-runner-token"
            );
          message = "cluster.githubRunner payload is configured while enable=false.";
        }
        {
          assertion = !cfg.enable || cfg.url != "";
          message = "cluster.githubRunner.url must be set when enable=true.";
        }
      ];
    }

    (lib.mkIf cfg.enable {
      services.github-runners.${cfg.name} = {
        enable = true;
        inherit (cfg) url tokenFile;
        replace = true;
        extraLabels = [ "nixos" ];
      };

      environment.persistence = lib.mkIf impermanenceEnabled {
        "/persist".directories = [
          "/var/lib/github-runners"
        ];
      };
    })
  ];
}
