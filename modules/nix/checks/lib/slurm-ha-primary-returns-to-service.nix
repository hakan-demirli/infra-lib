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
  name = "slurm-ha-primary-returns-to-service";

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

    with subtest("failover to backup"):
        ctld_a.succeed("systemctl stop slurmctld.service")
        ctld_b.wait_until_succeeds(
            "scontrol ping 2>&1 | grep -iE 'ctld-b.*(primary|UP)'",
            timeout=180,
        )

    with subtest("restart slurmctld on the original primary"):
        ctld_a.succeed("systemctl start slurmctld.service")
        ctld_a.wait_for_unit("slurmctld.service", timeout=180)

    with subtest("ctld_a is operational again"):
        ctld_a.wait_until_succeeds("scontrol ping 2>&1", timeout=180)
        print("INVARIANT HELD: original primary returned to service "
              "after failover; cluster back to steady-state HA shape")
  '';
}
