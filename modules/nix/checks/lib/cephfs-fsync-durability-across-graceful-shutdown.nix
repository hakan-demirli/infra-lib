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
  name = "cephfs-fsync-durability-across-graceful-shutdown";

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

    with subtest("client_1 writes + fsyncs durable.txt"):
        client_1.succeed(
            "echo 'durable-data-1' > /mnt/ceph/durable.txt",
            "sync /mnt/ceph/durable.txt",
        )
    with subtest("durable.txt visible from client_2 BEFORE shutdown"):
        v = client_2.wait_until_succeeds(
            "cat /mnt/ceph/durable.txt"
        ).strip()
        assert v == "durable-data-1", f"pre-shutdown propagation failed: {v!r}"

    with subtest("graceful shutdown of storage_c"):
        storage_c.shutdown()
        storage_a.wait_until_succeeds(
            "ceph osd stat | grep -E '3 osds: 2 up'", timeout=240
        )

    with subtest("durable.txt still readable after the shutdown"):
        v = client_2.wait_until_succeeds(
            "cat /mnt/ceph/durable.txt", timeout=60
        ).strip()
        assert v == "durable-data-1", (
            f"DURABILITY VIOLATION: client_2 lost durable.txt after "
            f"graceful shutdown of storage_c. Got: {v!r}"
        )
        print("INVARIANT HELD: fsync'd data survives graceful shutdown "
              "of one storage node")
  '';
}
