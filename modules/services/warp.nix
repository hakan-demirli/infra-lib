{
  lib,
  pkgs,
  host ? null,
  ...
}:
let
  labels = if host == null then { } else (host.labels or { });
  enable = (labels.warp or null) == "true";
in
{
  config = lib.mkIf enable {
    services.cloudflare-warp = {
      enable = true;
      package = pkgs.cloudflare-warp;
    };
    environment.persistence."/persist/system".directories = [
      "/var/lib/cloudflare-warp"
    ];
    systemd.user.services.warp-taskbar.wantedBy = [ "graphical.target" ];
  };
}
