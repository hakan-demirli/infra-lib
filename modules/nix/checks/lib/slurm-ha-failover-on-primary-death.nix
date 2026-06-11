{
  pkgs,
  ...
}:
let
  ha = import ./lib/slurm-ha-cluster.nix {
    inherit pkgs;
    inherit (pkgs) lib;
  };
in
pkgs.testers.runNixOSTest {
  name = "slurm-ha-failover-on-primary-death";

  nodes = {
    shared_state = ha.sharedStateNode;
    ctld_a = ha.mkCtldNode {
      hostname = "ctld-a";
      ip = ha.cfg.ctldAIp;
    };
    ctld_b = ha.mkCtldNode {
      hostname = "ctld-b";
      ip = ha.cfg.ctldBIp;
    };
    compute_1 = ha.mkComputeNode {
      hostname = "compute-1";
      ip = ha.cfg.compute1Ip;
    };
    compute_2 = ha.mkComputeNode {
      hostname = "compute-2";
      ip = ha.cfg.compute2Ip;
    };
  };

  testScript = ''
    ${ha.bootstrapScript}

    with subtest("kill the primary slurmctld"):
        ctld_a.succeed("systemctl stop slurmctld.service")

    with subtest("backup takes over"):
        ctld_b.wait_until_succeeds(
            "scontrol ping 2>&1 | grep -iE 'ctld-b.*(primary|UP)'",
            timeout=180,
        )
        print("INVARIANT HELD: backup slurmctld took over within "
              "SlurmctldTimeout after primary died")
  '';
}
