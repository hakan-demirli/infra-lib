{
  config,
  lib,
  host ? null,
  ...
}:
let
  cfg = config.services.tailscale;
  hostLabels = if host == null then { } else (host.labels or { });
  authKeyDefault = (hostLabels.tailscale_auth_key or "true") == "true";
  advertiseBootstrap = (hostLabels.tailscale_bootstrap_tag or "true") == "true";
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
        `tailscale_auth_key = "false"`. When false, the operator must run
        `sudo tailscale up --login-server=... --advertise-tags=...` by hand.
      '';
    };
    advertiseBootstrapTag = lib.mkOption {
      type = lib.types.bool;
      default = advertiseBootstrap;
      description = ''
        Whether to advertise `tag:bootstrap` on first login. The
        headscale ACL gives this tag NO outbound and only admin
        inbound; promote with
          sudo headscale nodes tag -i <id> -t tag:<real>
        once the node is in inventory.
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
        "--login-server=https://${cfg.loginServerHost}"
      ]
      ++ lib.optional cfg.advertiseBootstrapTag "--advertise-tags=tag:bootstrap";
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
    environment.persistence."/persist/system".directories = [
      "/var/lib/tailscale"
    ];

    systemd.services.tailscaled-autoconnect = {
      unitConfig = {
        DefaultDependencies = false;
      };
      serviceConfig = {
        TimeoutStartSec = "5s";
        Restart = "no";
      };
    };
  };
}
