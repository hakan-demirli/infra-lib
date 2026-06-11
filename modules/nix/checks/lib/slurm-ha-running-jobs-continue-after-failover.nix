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
  name = "slurm-ha-running-jobs-continue-after-failover";

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

    with subtest("submit a long-running job and wait until RUNNING"):
        out = ctld_a.succeed(
            "sbatch --no-requeue --ntasks=1 --time=5 --wrap='sleep 60'"
        ).strip()
        assert "Submitted batch job" in out, f"sbatch failed: {out!r}"
        job_id = out.split()[-1]
        ctld_a.wait_until_succeeds(
            f"squeue -t R -h -o %i | grep -q '^{job_id}$'", timeout=120
        )

    with subtest("kill the primary slurmctld while the job is running"):
        ctld_a.succeed("systemctl stop slurmctld.service")
        ctld_b.wait_until_succeeds(
            "scontrol ping 2>&1 | grep -iE 'ctld-b.*(primary|UP)'",
            timeout=180,
        )

    with subtest("job state on backup is RUNNING / COMPLETING / COMPLETED"):
        info = ctld_b.succeed(f"scontrol show job {job_id} 2>&1")
        ok_states = ["RUNNING", "COMPLETING", "COMPLETED"]
        bad_states = ["NODE_FAIL", "FAILED", "CANCELLED", "TIMEOUT"]
        for bad in bad_states:
            assert f"JobState={bad}" not in info, (
                f"job entered forbidden state {bad} after failover. "
                f"slurmctld killed in-flight work mid-failover.\n"
                f"--- scontrol show job ---\n{info}"
            )
        assert any(f"JobState={ok}" in info for ok in ok_states), (
            f"job in unexpected state after failover.\n"
            f"--- scontrol show job ---\n{info}"
        )
        print("INVARIANT HELD: an in-flight job survived the primary "
              "slurmctld being killed (no NODE_FAIL / FAILED / "
              "CANCELLED / TIMEOUT in the post-failover job state)")
  '';
}
