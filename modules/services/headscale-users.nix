{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.headscale-users;
in
{
  options.services.headscale-users = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Create the missing Headscale users of a list. Users are never deleted.";
    };
    usersFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "File with one Headscale user name per line";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.enable || cfg.usersFile == null;
          message = "services.headscale-users payload is configured while enable=false.";
        }
        {
          assertion = !cfg.enable || (cfg.usersFile != null && config.services.headscale.enable);
          message = "services.headscale-users requires usersFile and services.headscale.enable when enabled.";
        }
      ];
    }

    (lib.mkIf cfg.enable {
      systemd.services.headscale-users = {
        description = "Create the missing Headscale users";
        after = [ "headscale.service" ];
        requires = [ "headscale.service" ];
        wantedBy = [ "multi-user.target" ];
        restartTriggers = [ cfg.usersFile ];
        path = [
          config.services.headscale.package
          pkgs.jq
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          attempt=0
          until existing="$(headscale users list --output json)"; do
            attempt=$((attempt + 1))
            if [ "$attempt" -ge 60 ]; then
              echo "headscale did not answer" >&2
              exit 1
            fi
            sleep 1
          done
          known="$(printf '%s' "$existing" | jq -r '.[]?.name')"

          while IFS= read -r user; do
            if ! grep -qxF -- "$user" <<< "$known"; then
              headscale users create "$user"
            fi
          done < ${cfg.usersFile}
        '';
      };
    })
  ];
}
