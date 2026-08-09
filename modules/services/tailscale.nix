{
  config,
  lib,
  pkgs,
  host ? null,
  ...
}:
let
  cfg = config.services.tailscale;
  hostLabels = if host == null then { } else (host.labels or { });
  authKeyDefault = (hostLabels.tailscale_auth_key or "true") == "true";
  impermanenceEnabled = host != null && (host.impermanence.enable or false);
  inherit (cfg) authKeyFile;
  authKeyParameters = lib.pipe cfg.authKeyParameters [
    (lib.filterAttrs (_: value: value != null))
    (lib.mapAttrsToList (
      name: value: "${name}=${if builtins.isBool value then lib.boolToString value else toString value}"
    ))
    (builtins.concatStringsSep "&")
    (parameters: if parameters == "" then "" else "?${parameters}")
  ];
in
{
  options.services.tailscale = {
    loginServerHost = lib.mkOption {
      type = lib.types.str;
      description = "Headscale login server hostname";
    };
    useAuthKey = lib.mkOption {
      type = lib.types.bool;
      default = authKeyDefault;
      description = ''
        Whether to use a sops-managed auth key for automatic registration.
        Default is true unless overridden by host label
        `tailscale_auth_key = "false"`. Auth keys that create tagged nodes
        must carry their tags server-side.
      '';
    };
  };

  config = {
    sops.secrets.tailscale-key = lib.mkIf cfg.useAuthKey { };

    services.tailscale = {
      enable = true;
      authKeyFile = lib.mkIf cfg.useAuthKey config.sops.secrets.tailscale-key.path;
      useRoutingFeatures = "client";
      extraUpFlags = [
        "--reset"
        "--login-server=https://${cfg.loginServerHost}"
      ];
    };

    networking = {
      firewall = {
        checkReversePath = "loose";
        trustedInterfaces = [ "tailscale0" ];
        allowedUDPPorts = [ config.services.tailscale.port ];
      };

      networkmanager.unmanaged = [ "tailscale0" ];
      networkmanager.dns = "systemd-resolved";
    };

    services.resolved.enable = true;
    environment.persistence = lib.mkIf impermanenceEnabled {
      "/persist/system".directories = [
        "/var/lib/tailscale"
      ];
    };

    systemd.services.tailscaled-autoconnect = lib.mkMerge [
      {
        unitConfig.DefaultDependencies = false;
        serviceConfig.Restart = "no";
      }
      (lib.mkIf (authKeyFile != null) {
        after = lib.optional cfg.useAuthKey "sops-install-secrets.service";
        requires = lib.optional cfg.useAuthKey "sops-install-secrets.service";
        serviceConfig = {
          LoadCredential = [ "auth-key:${authKeyFile}" ];
          RuntimeDirectory = "tailscaled-autoconnect";
          RuntimeDirectoryMode = "0700";
          TimeoutStartSec = "60s";
        };
        script = lib.mkForce ''
          getState() {
            ${lib.getExe cfg.package} status --json --peers=false \
              | ${lib.getExe pkgs.jq} -r '.BackendState'
          }

          auth_key_file="$CREDENTIALS_DIRECTORY/auth-key"
          ${lib.optionalString (authKeyParameters != "") ''
            runtime_auth_key="$RUNTIME_DIRECTORY/auth-key"
            ${pkgs.coreutils}/bin/tr -d '\n' < "$auth_key_file" > "$runtime_auth_key"
            printf '%s' ${lib.escapeShellArg authKeyParameters} >> "$runtime_auth_key"
            ${pkgs.coreutils}/bin/chmod 0600 "$runtime_auth_key"
            auth_key_file="$runtime_auth_key"
          ''}

          lastState=""
          while state="$(getState)"; do
            if [[ "$state" != "$lastState" ]]; then
              case "$state" in
                NeedsLogin|NeedsMachineAuth|Stopped)
                  echo "Server needs authentication, sending auth key file"
                  ${lib.getExe cfg.package} up \
                    --auth-key "file:$auth_key_file" \
                    ${lib.escapeShellArgs cfg.extraUpFlags}
                  ;;
                Running)
                  echo "Tailscale is running"
                  ${pkgs.systemd}/bin/systemd-notify --ready
                  exit 0
                  ;;
                *)
                  echo "Waiting for Tailscale State = Running or systemd timeout"
                  ;;
              esac
              echo "State = $state"
            fi
            lastState="$state"
            ${pkgs.coreutils}/bin/sleep .5
          done
        '';
      })
    ];
  };
}
