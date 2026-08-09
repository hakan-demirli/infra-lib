{
  config,
  lib,
  pkgs,
  ...
}:
let
  hasMungeSecret = lib.hasAttrByPath [ "sops" "secrets" "munge-key" ] config;
in
{
  config = lib.mkIf (config.services.munge.enable && hasMungeSecret) {
    services.munge.password = "/run/munge/munge.key";

    systemd.services.munged = {
      after = [ "sops-install-secrets.service" ];
      requires = [ "sops-install-secrets.service" ];
      serviceConfig.ExecStartPre = lib.mkForce [
        "+${pkgs.coreutils}/bin/install -o munge -g munge -m 0400 ${
          config.sops.secrets."munge-key".path
        } /run/munge/munge.key"
      ];
    };
  };
}
