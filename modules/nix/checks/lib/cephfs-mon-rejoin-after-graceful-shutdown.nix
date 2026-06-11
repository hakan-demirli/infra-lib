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
  name = "cephfs-mon-rejoin-after-graceful-shutdown";

  nodes = {
    storage_a = cluster.storageANode;
    storage_b = cluster.storageBNode;
    storage_c = cluster.storageCNode;
  };

  testScript = ''
    ${cluster.bootstrapScript}

    with subtest("graceful shutdown of storage_c"):
        storage_c.shutdown()
        storage_a.wait_until_succeeds(
            "ceph -s 2>/dev/null | grep -E 'quorum [^c]+$|out of quorum'",
            timeout=240,
        )

    with subtest("storage_c restarts"):
        storage_c.start()
        storage_c.wait_for_unit("network.target")
        storage_c.wait_for_unit(
            "ceph-mon-${cluster.cfg.monC.name}", timeout=120
        )

    with subtest("mon-c rejoins quorum + member list shows all 3"):
        storage_a.wait_until_succeeds(
            "ceph -s 2>/dev/null | grep -E 'quorum .*${cluster.cfg.monC.name}'",
            timeout=180,
        )
        print("INVARIANT HELD: mon-c rejoined quorum after graceful "
              "shutdown without operator intervention")
  '';
}
