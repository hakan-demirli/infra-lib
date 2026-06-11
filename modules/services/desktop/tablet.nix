{
  lib,
  pkgs,
  host ? null,
  ...
}:
let
  labels = if host == null then { } else (host.labels or { });
  enable = (labels.tablet or null) == "true";
in
{
  config = lib.mkIf enable {
    hardware.sensor.iio.enable = true;

    environment.systemPackages = with pkgs; [
      wvkbd
    ];
  };
}
