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
  name = "cephfs-writes-available-with-one-storage-down";

  nodes = {
    storage_a = cluster.storageANode;
    storage_b = cluster.storageBNode;
    storage_c = cluster.storageCNode;
    client_1 = cluster.mkClientNode "192.168.1.10";
    client_2 = cluster.mkClientNode "192.168.1.11";
  };

  testScript = ''
    ${cluster.bootstrapScript}

    ${cluster.mkClientMount "client_1"}
    ${cluster.mkClientMount "client_2"}

    with subtest("crash storage_c + wait for OSD-2 to be marked down"):
        storage_c.crash()
        storage_a.wait_until_succeeds(
            "ceph osd stat | grep -E '3 osds: 2 up'", timeout=240
        )

    with subtest("client_1 writes a new file during the outage"):
        client_1.succeed(
            "echo 'written-during-outage' > /mnt/ceph/during-outage.txt",
            "sync /mnt/ceph/during-outage.txt",
        )
        print("OK: write succeeded against the 2-OSD surviving cluster")

    with subtest("client_2 sees the new write"):
        v = client_2.wait_until_succeeds(
            "cat /mnt/ceph/during-outage.txt", timeout=60
        ).strip()
        assert v == "written-during-outage", (
            f"new write didn't propagate during outage; got: {v!r}"
        )
        print("INVARIANT HELD: new writes succeed + propagate cross-"
              "client when one storage node is down (replica=3, "
              "min_size=2 with 2 OSDs alive is enough)")
  '';
}
