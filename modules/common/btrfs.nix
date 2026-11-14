{
  config,
  lib,
  ...
}:
let
  rootIsBtrfs = (config.fileSystems."/".fsType or "") == "btrfs";
  anyBtrfs = lib.any (fs: fs.fsType == "btrfs") (lib.attrValues config.fileSystems);
in
{
  config = lib.mkMerge [
    (lib.mkIf rootIsBtrfs {
      services.btrfs.autoScrub = {
        enable = true;
        interval = "Sun *-*-* 03:00:00";
        fileSystems = [ "/" ];
      };

      systemd.timers."btrfs-scrub@".timerConfig.AccuracySec = lib.mkForce "10m";

      systemd.services."btrfs-scrub@".unitConfig.ConditionACPower = true;

      system.impermanence.persistentDirs = [ "/var/lib/btrfs" ];
    })

    # Data block groups fill all device space, so metadata cannot grow and writes fail
    # while df still reports free space. The kernel resets these knobs on each mount.
    (lib.mkIf anyBtrfs {
      systemd.tmpfiles.rules = [
        "w /sys/fs/btrfs/*/allocation/data/dynamic_reclaim - - - - 1"
        "w /sys/fs/btrfs/*/allocation/data/periodic_reclaim - - - - 1"
      ];
    })
  ];
}
