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
  name = "slurm-ha-shared-queue-state";

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

    with subtest("submit a job on the primary"):
        out = ctld_a.succeed(
            "sbatch --wrap='sleep 60' -J shared-state-canary"
        ).strip()
        assert "Submitted batch job" in out, f"sbatch failed: {out!r}"
        job_id = out.split()[-1]

    with subtest("backup sees the same job in its queue"):
        squeue_b = ctld_b.succeed("squeue -h -o %i")
        assert job_id in squeue_b, (
            f"job {job_id} submitted on ctld_a not visible on ctld_b. "
            f"squeue on ctld_b: {squeue_b!r}. "
            f"Shared StateSaveLocation is NOT actually shared."
        )
        print("INVARIANT HELD: queue state at /var/spool/slurm-state "
              "(NFS-shared) is visible from both primary and backup "
              "slurmctld -- HA state-sharing precondition met")
  '';
}
