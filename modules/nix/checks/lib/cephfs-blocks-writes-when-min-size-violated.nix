{
  pkgs,
  ...
}:
let
  cluster = import ./lib/ceph-cluster.nix {
    inherit pkgs;
    inherit (pkgs) lib;
  };
in
pkgs.testers.runNixOSTest {
  name = "cephfs-blocks-writes-when-min-size-violated";

  nodes = {
    storage_a = cluster.storageANode;
    storage_b = cluster.storageBNode;
    storage_c = cluster.storageCNode;
    client_1 = cluster.mkClientNode "192.168.1.10";
  };

  testScript = ''
    ${cluster.bootstrapScript}

    ${cluster.mkClientMount "client_1"}

    with subtest("stop ceph-osd-1 and ceph-osd-2 (2 of 3 OSDs out)"):
        storage_b.succeed("systemctl stop ceph-osd-${cluster.cfg.osd1.name}")
        storage_c.succeed("systemctl stop ceph-osd-${cluster.cfg.osd2.name}")
        storage_a.wait_until_succeeds(
            "ceph osd stat | grep -E '3 osds: 1 up'", timeout=120
        )

    with subtest("write attempt remains blocked"):
        client_1.succeed(
            "rm -f /tmp/blocked-write-completed && "
            "systemd-run --unit=cephfs-blocked-write --property=Type=oneshot "
            "--no-block sh -c 'echo blocked-write > /mnt/ceph/blocked.txt "
            "&& sync /mnt/ceph/blocked.txt "
            "&& touch /tmp/blocked-write-completed'"
        )
        client_1.succeed("sleep 10")
        client_1.fail("test -e /tmp/blocked-write-completed")
        state = client_1.succeed(
            "systemctl show -p ActiveState --value cephfs-blocked-write.service"
        ).strip()
        assert state == "activating", (
            f"SAFETY VIOLATION: write did not remain blocked with 2-of-3 OSDs "
            f"unreachable. min_size=2 requires the write to block, but the "
            f"transient unit state is {state!r}."
        )
        print("INVARIANT HELD: write remains blocked when min_size=2 cannot be satisfied")
        client_1.crash()
  '';
}
