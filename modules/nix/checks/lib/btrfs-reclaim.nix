{ pkgs, self }:
pkgs.testers.runNixOSTest {
  name = "btrfs-reclaim";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ (self + "/modules/common/btrfs.nix") ];

      options.system.impermanence.persistentDirs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };

      config = {
        virtualisation = {
          emptyDiskImages = [
            {
              size = 1024;
              driveConfig.deviceExtraOpts.serial = "data";
            }
          ];
          fileSystems."/data" = {
            device = "/dev/disk/by-id/virtio-data";
            fsType = "btrfs";
            autoFormat = true;
          };
        };

        system.stateVersion = "26.05";
      };
    };

  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")

    knobs = machine.succeed(
        "ls /sys/fs/btrfs/*/allocation/data/dynamic_reclaim /sys/fs/btrfs/*/allocation/data/periodic_reclaim"
    ).split()
    assert len(knobs) == 2, knobs
    for knob in knobs:
        value = machine.succeed(f"cat {knob}").strip()
        assert value == "1", f"{knob} is {value}"
  '';
}
