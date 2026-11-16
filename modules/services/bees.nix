{
  config,
  lib,
  host,
  ...
}:
let
  hardware = import ../lib/hardware.nix;
  rootFsType = config.fileSystems."/".fsType or null;
  hashTableSizeMB = lib.max 128 (host.hardware.ram_mib / 1024 * 16);
in
{
  assertions = [
    {
      assertion = rootFsType == "btrfs";
      message = "services/bees deduplicates the root filesystem, which must be btrfs; / is ${toString rootFsType}.";
    }
  ];

  services.beesd.filesystems.root = {
    spec = "/";
    inherit hashTableSizeMB;
    verbosity = "warning";
    extraOptions = [
      "--loadavg-target"
      (toString (hardware.logicalCpus host.hardware))
      "--thread-min"
      "1"
      "--throttle-factor"
      "2.0"
    ];
  };

  systemd.services."beesd@root".serviceConfig = {
    OOMScoreAdjust = 1000;
    RestartSec = "5min";
  };
}
