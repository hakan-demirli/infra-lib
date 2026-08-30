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

    with subtest("submit a long-running job and wait for its payload"):
        out = ctld_a.succeed(
            "sbatch --no-requeue --nodelist=compute-1 --ntasks=1 "
            "--time=10 --wrap='echo $$ > "
            "/tmp/slurm-job-$SLURM_JOB_ID.pid; exec sleep 300'"
        ).strip()
        assert "Submitted batch job" in out, f"sbatch failed: {out!r}"
        job_id = out.split()[-1]
        payload_pid_file = f"/tmp/slurm-job-{job_id}.pid"
        payload_is_running = (
            f"test -r {payload_pid_file} && "
            f"test \"$(cat /proc/$(cat {payload_pid_file})/comm)\" = sleep"
        )
        ctld_a.wait_until_succeeds(
            f"scontrol show job {job_id} -o | grep -q 'JobState=RUNNING'",
            timeout=120,
        )
        compute_1.wait_until_succeeds(payload_is_running, timeout=120)
        info = ctld_a.succeed(f"scontrol show job {job_id} -o")
        assert "Restarts=0" in info, f"job was requeued during launch:\n{info}"

    with subtest("kill the primary slurmctld while the job is running"):
        ctld_a.succeed("systemctl stop slurmctld.service")
        wait_for_backup_takeover()

    with subtest("job remains running after backup takeover"):
        info = ctld_b.succeed(f"scontrol show job {job_id} -o 2>&1")
        assert "JobState=RUNNING" in info, (
            f"job did not remain running after failover.\n"
            f"--- scontrol show job ---\n{info}"
        )
        compute_1.succeed(payload_is_running)
        ctld_b.succeed(f"scancel {job_id}")
        print("INVARIANT HELD: an in-flight job remained running after "
              "the backup slurmctld took over")
  '';
}
