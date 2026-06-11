{ config, lib, ... }:
let
  cfg = config.services.tailscale;
in
{
  options.services.tailscale = {
    loginServerHost = lib.mkOption {
      type = lib.types.str;
      description = "Headscale login server hostname";
    };
    useAuthKey = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to use a sops-managed auth key for automatic registration. When false, register manually via `sudo tailscale up`.";
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
