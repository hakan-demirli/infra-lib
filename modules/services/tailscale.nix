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
          getStatus() {
            ${lib.getExe cfg.package} status --json --peers=false \
              || true
          }

          auth_key_file="$CREDENTIALS_DIRECTORY/auth-key"
          ${lib.optionalString (authKeyParameters != "") ''
            runtime_auth_key="$RUNTIME_DIRECTORY/auth-key"
            ${pkgs.coreutils}/bin/tr -d '\n' < "$auth_key_file" > "$runtime_auth_key"
            printf '%s' ${lib.escapeShellArg authKeyParameters} >> "$runtime_auth_key"
            ${pkgs.coreutils}/bin/chmod 0600 "$runtime_auth_key"
            auth_key_file="$runtime_auth_key"
          ''}

          auth_key_fingerprint="$(${pkgs.coreutils}/bin/sha256sum "$auth_key_file")"
          auth_key_fingerprint="''${auth_key_fingerprint%% *}"
          auth_key_fingerprint_file=/var/lib/tailscale/bootstrap-auth-key.sha256
          stored_auth_key_fingerprint=
          if [[ -r "$auth_key_fingerprint_file" ]]; then
            IFS= read -r stored_auth_key_fingerprint < "$auth_key_fingerprint_file" || true
          fi

          storeAuthKeyFingerprint() {
            ${pkgs.coreutils}/bin/install -d -m 0700 /var/lib/tailscale
            fingerprint_staged="$(${pkgs.coreutils}/bin/mktemp /var/lib/tailscale/.bootstrap-auth-key.XXXXXX)"
            ${pkgs.coreutils}/bin/printf '%s\n' "$auth_key_fingerprint" > "$fingerprint_staged"
            ${pkgs.coreutils}/bin/chmod 0600 "$fingerprint_staged"
            ${pkgs.coreutils}/bin/mv -f "$fingerprint_staged" "$auth_key_fingerprint_file"
            stored_auth_key_fingerprint="$auth_key_fingerprint"
          }

          reauthentication_attempted=false
          lastState=""
          while status="$(getStatus)" && [[ -n "$status" ]]; do
            state="$(${lib.getExe pkgs.jq} -r '.BackendState' <<< "$status")"
            online="$(${lib.getExe pkgs.jq} -r '.Self.Online // false' <<< "$status")"
            observed_state="$state:$online"
            if [[ "$observed_state" != "$lastState" ]]; then
              case "$state" in
                NeedsLogin|NeedsMachineAuth|Stopped)
                  echo "Server needs authentication, sending auth key file"
                  ${lib.getExe cfg.package} up \
                    --auth-key "file:$auth_key_file" \
                    ${lib.escapeShellArgs cfg.extraUpFlags}
                  reauthentication_attempted=true
                  ;;
                Running)
                  if [[ "$online" == true ]]; then
                    if [[ "$stored_auth_key_fingerprint" != "$auth_key_fingerprint" ]]; then
                      storeAuthKeyFingerprint
                    fi
                    echo "Tailscale is running"
                    ${pkgs.systemd}/bin/systemd-notify --ready
                    exit 0
                  elif [[ "$stored_auth_key_fingerprint" != "$auth_key_fingerprint" \
                    && "$reauthentication_attempted" == false ]]; then
                    echo "Tailscale identity is stale, reauthenticating with bootstrap key file"
                    ${lib.getExe cfg.package} up \
                      --force-reauth \
                      --auth-key "file:$auth_key_file" \
                      ${lib.escapeShellArgs cfg.extraUpFlags}
                    reauthentication_attempted=true
                  elif [[ "$stored_auth_key_fingerprint" == "$auth_key_fingerprint" ]]; then
                    echo "Tailscale is running without current control connectivity"
                    ${pkgs.systemd}/bin/systemd-notify --ready
                    exit 0
                  fi
                  ;;
                *)
                  echo "Waiting for Tailscale State = Running or systemd timeout"
                  ;;
              esac
              echo "State = $state"
            fi
            lastState="$observed_state"
            ${pkgs.coreutils}/bin/sleep .5
          done
        '';
      })
    ];
  };
}
