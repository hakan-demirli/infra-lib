{
  config,
  lib,
  ...
}:
let
  enabled = (config.fileSystems."/".fsType or "") == "btrfs";
in
{
  config = lib.mkIf enabled {
    services.btrfs.autoScrub = {
      enable = true;
      interval = "Sun *-*-* 03:00:00";
      fileSystems = [ "/" ];
    };

    systemd.timers."btrfs-scrub@".timerConfig.AccuracySec = lib.mkForce "10m";

    systemd.services."btrfs-scrub@".unitConfig.ConditionACPower = true;

    system.impermanence.persistentDirs = [ "/var/lib/btrfs" ];
  };
}
