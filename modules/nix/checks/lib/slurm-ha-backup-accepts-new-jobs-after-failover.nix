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
  name = "slurm-ha-backup-accepts-new-jobs-after-failover";

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

    with subtest("backup accepts a new sbatch submission"):
        out = ctld_b.succeed(
            "sbatch --wrap='echo hello-from-failed-over-cluster' "
            "-J post-failover-job"
        ).strip()
        assert "Submitted batch job" in out, (
            f"backup ctld rejected new submission post-failover: {out!r}"
        )
        print("INVARIANT HELD: backup ctld is fully operational and "
              "accepts new sbatch submissions after takeover")
  '';
}
