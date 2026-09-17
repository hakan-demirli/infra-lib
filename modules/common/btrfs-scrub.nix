{
  config,
  lib,
  utils,
  ...
}:
let
  enabled = (config.fileSystems."/".fsType or "") == "btrfs";
  unit = "btrfs-scrub-${utils.escapeSystemdPath "/"}";
in
{
  config = lib.mkIf enabled {
    services.btrfs.autoScrub = {
      enable = true;
      interval = "Sun *-*-* 03:00:00";
      fileSystems = [ "/" ];
    };

    systemd.timers.${unit}.timerConfig.AccuracySec = lib.mkForce "10m";

    systemd.services.${unit}.unitConfig.ConditionACPower = true;

    system.impermanence.persistentDirs = [ "/var/lib/btrfs" ];
  };
}
