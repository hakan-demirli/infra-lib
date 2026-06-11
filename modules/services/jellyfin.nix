{
  lib,
  host ? null,
  ...
}:
let
  impermanenceEnabled = host != null && (host.impermanence.enable or false);
in
{
  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };

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
