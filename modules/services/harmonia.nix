{
  config,
  lib,
  pkgs,
  ...
}:
let
  sopsEval = lib.tryEval (config.sops.defaultSopsFile or null);
  hasSops = sopsEval.success && sopsEval.value != null;
  fallbackKeyPath = "/var/lib/secrets/nix-serve-key";
in
{
  sops.secrets = lib.mkIf hasSops {
    nix-serve-key = { };
  };

  services.harmonia.cache = {
    enable = true;
    signKeyPaths = if hasSops then [ config.sops.secrets.nix-serve-key.path ] else [ fallbackKeyPath ];
    settings.bind = "[::]:5101";
  };

  systemd.services.harmonia-fallback-key = lib.mkIf (!hasSops) {
    description = "Generate a host-local nix-serve signing key";
    wantedBy = [ "multi-user.target" ];
    before = [ "harmonia.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      mkdir -p /var/lib/secrets
      if [ ! -s ${fallbackKeyPath} ]; then
        ${pkgs.nix}/bin/nix-store --generate-binary-cache-key \
          "fallback-${config.networking.hostName}" \
          ${fallbackKeyPath} ${fallbackKeyPath}.pub
        chmod 0400 ${fallbackKeyPath}
      fi
    '';
  };

  networking.firewall.allowedTCPPorts = [ 5101 ];
}
