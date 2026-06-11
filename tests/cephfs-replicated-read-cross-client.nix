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
  name = "cephfs-replicated-read-cross-client";

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

    with subtest("client_1 writes, client_2 reads"):
        client_1.succeed("echo 'shared-data' > /mnt/ceph/hello.txt")
        client_1.succeed("sync /mnt/ceph/hello.txt")
        v = client_2.wait_until_succeeds(
            "cat /mnt/ceph/hello.txt", timeout=60
        ).strip()
        assert v == "shared-data", (
            f"cross-client coherence broken: client_2 got {v!r}"
        )
        print("INVARIANT HELD: data written from one cephfs client is "
              "visible from another (basic shared-FS sanity)")
  '';
}
