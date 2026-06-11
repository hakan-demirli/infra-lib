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
  name = "cephfs-mon-rejoin-after-hard-crash";

  nodes = {
    storage_a = cluster.storageANode;
    storage_b = cluster.storageBNode;
    storage_c = cluster.storageCNode;
  };

  testScript = ''
    ${cluster.bootstrapScript}

    with subtest("hard crash of storage_c (also takes mon-c)"):
        storage_c.crash()
        storage_a.wait_until_succeeds(
            "ceph -s 2>/dev/null | grep -E 'quorum [^c]+$|out of quorum'",
            timeout=240,
        )

    with subtest("storage_c reboots; mon-c systemd unit comes up"):
        storage_c.start()
        storage_c.wait_for_unit("network.target")
        storage_c.wait_for_unit(
            "ceph-mon-${cluster.cfg.monC.name}", timeout=120
        )

    with subtest("mon-c rejoins quorum"):
        storage_a.wait_until_succeeds(
            "ceph -s 2>/dev/null | grep -E 'quorum .*${cluster.cfg.monC.name}'",
            timeout=180,
        )
        print("INVARIANT HELD: mon-c rejoined quorum after hard crash "
              "+ reboot, no operator action needed")
  '';
}
