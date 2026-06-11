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

    with subtest("write attempt blocks (does not succeed)"):
        rc, out = client_1.execute(
            "timeout 20 sh -c 'echo blocked-write > /mnt/ceph/blocked.txt && sync /mnt/ceph/blocked.txt'"
        )
        assert rc != 0, (
            f"SAFETY VIOLATION: write succeeded with 2-of-3 OSDs "
            f"unreachable. min_size=2 should have BLOCKED this. "
            f"rc={rc}, output={out!r}. "
            f"Split-brain risk: the single surviving OSD now has "
            f"data the rest of the cluster doesn't know about."
        )
        print(f"INVARIANT HELD: write blocked when min_size=2 cannot "
              f"be satisfied (rc={rc}, expected non-zero / timeout)")
  '';
}
