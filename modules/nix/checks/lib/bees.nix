{ pkgs, self }:
let
  disk = "/dev/vda";
  partition = "/dev/disk/by-label/storage";
  someContentIsShared = pkgs.writeShellScript "some-content-is-shared" ''
    [[ $(${pkgs.btrfs-progs}/bin/btrfs filesystem du -s --raw /var/lib/dedupe-{1,2} \
      | ${pkgs.gawk}/bin/awk 'NR > 1 && $3 == 0 { count++ } END { print count + 0 }') -eq 0 ]]
  '';
in
pkgs.testers.runNixOSTest {
  name = "bees";

  nodes.machine = {
    imports = [ (self + "/modules/services/bees.nix") ];

    _module.args.host.hardware = {
      cpu_sockets = 1;
      cpu_cores_per_socket = 2;
      cpu_threads_per_core = 1;
      cpu_logical_count = null;
      ram_mib = 12288;
    };

    virtualisation = {
      memorySize = 2048;
      rootDevice = disk;
      useDefaultFilesystems = false;
      fileSystems."/" = {
        device = partition;
        fsType = "btrfs";
        options = [ "subvol=/root" ];
      };
    };

    systemd.repart.partitions."00-root" = {
      Type = "linux-generic";
      Format = "btrfs";
      Label = "storage";
      Subvolumes = [ "/root" ];
      MakeDirectories = [ "/root" ];
    };

    boot.initrd = {
      supportedFilesystems = [ "btrfs" ];
      systemd.repart = {
        enable = true;
        device = disk;
        empty = "allow";
      };
    };

    system.stateVersion = "26.05";
  };

  testScript = ''
    machine.wait_for_unit("beesd@root.service")
    machine.wait_until_succeeds("ls /run/bees/*.status")

    with subtest("bees runs with the limits derived from the inventory"):
        pid = machine.succeed("systemctl show --property=MainPID --value beesd@root.service").strip()
        machine.succeed(f"readlink /proc/{pid}/exe | grep -q '/lib/bees/bees$'")
        machine.succeed(f"test $(cat /proc/{pid}/oom_score_adj) = 1000")
        args = machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/cmdline").splitlines()
        for option, value in [("--loadavg-target", "2"), ("--thread-min", "1"), ("--throttle-factor", "2.0")]:
            assert args[args.index(option) + 1] == value, f"{option} in {args}"

    with subtest("the hash table is sized from RAM and kept outside the root subvolume"):
        machine.succeed("mkdir /top && mount -o subvolid=5 ${partition} /top")
        machine.succeed("test $(stat -c %s /top/.beeshome/beeshash.dat) = $((192 * 1024 * 1024))")
        machine.succeed("umount /top")

    with subtest("bees shares the extents of identical files"):
        machine.succeed("systemctl stop beesd@root.service")
        machine.succeed(
            "dd if=/dev/urandom of=/var/lib/dedupe-1 bs=1M count=8",
            "cp --reflink=never /var/lib/dedupe-1 /var/lib/dedupe-2",
            "sync",
        )
        machine.fail("${someContentIsShared}")
        machine.succeed("systemctl start beesd@root.service")
        machine.wait_until_succeeds("${someContentIsShared}")
  '';
}
