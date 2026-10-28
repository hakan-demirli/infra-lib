{
  lib,
  host ? null,
  ...
}:
let
  impermanenceEnabled = host != null && (host.impermanence.enable or false);
in
{
  imports = [ ../common/tailnet-only-ports.nix ];

  services.jellyfin.enable = true;

  cluster.firewall.tailnetOnlyTCPPorts = [
    8096
    8920
  ];

  environment.persistence = lib.mkIf impermanenceEnabled {
    "/persist/system".directories = [
      {
        directory = "/var/lib/jellyfin";
        user = "jellyfin";
        group = "jellyfin";
        mode = "0700";
      }
    ];
  };
}
