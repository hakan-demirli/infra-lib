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
  name = "cephfs-osd-rejoin-after-hard-crash";

  nodes = {
    storage_a = cluster.storageANode;
    storage_b = cluster.storageBNode;
    storage_c = cluster.storageCNode;
  };

  testScript = ''
    ${cluster.bootstrapScript}

    with subtest("hard crash of storage_c"):
        storage_c.crash()
        storage_a.wait_until_succeeds(
            "ceph osd stat | grep -E '3 osds: 2 up'", timeout=240
        )

    with subtest("storage_c reboots"):
        storage_c.start()
        storage_c.wait_for_unit("network.target")
        storage_c.wait_for_unit("ceph-mon-${cluster.cfg.monC.name}", timeout=120)

    with subtest("OSD-2 rejoins the active set after crash"):
        storage_c.wait_for_unit(
            "ceph-osd-${cluster.cfg.osd2.name}", timeout=180
        )
        storage_a.wait_until_succeeds(
            "ceph osd stat | grep -e '3 osds: 3 up[^,]*, 3 in'",
            timeout=300,
        )
        print("INVARIANT HELD: OSD-2 rejoined active+in set after "
              "hard crash + reboot, no operator action needed")
  '';
}
