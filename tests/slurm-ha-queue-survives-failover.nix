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
  name = "slurm-ha-queue-survives-failover";

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

    with subtest("submit 3 long-running jobs against the primary"):
        job_ids = []
        for i in range(3):
            out = ctld_a.succeed(
                f"sbatch --wrap='sleep 120' -J survives-{i}"
            ).strip()
            assert "Submitted batch job" in out
            job_ids.append(out.split()[-1])

    with subtest("wait until primary's queue has all 3 jobs persisted"):
        ctld_a.wait_until_succeeds(
            "squeue -h -o %i | wc -l | grep -q '^3$'", timeout=60
        )

    with subtest("kill primary; wait for backup takeover"):
        ctld_a.succeed("systemctl stop slurmctld.service")
        ctld_b.wait_until_succeeds(
            "scontrol ping 2>&1 | grep -iE 'ctld-b.*(primary|UP)'",
            timeout=180,
        )

    with subtest("all 3 jobs still in queue on the backup"):
        squeue_b = ctld_b.succeed("squeue -h -o %i")
        missing = [j for j in job_ids if j not in squeue_b]
        assert not missing, (
            f"jobs lost across failover: {missing}. "
            f"squeue on backup: {squeue_b!r}"
        )
        print(f"INVARIANT HELD: all {len(job_ids)} pre-failover jobs "
              f"still visible on the backup ctld after takeover")
  '';
}
