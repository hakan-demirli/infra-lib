{
  pkgs,
  ...
}:
let
  cluster = import ./lib/slurm-on-cephfs-cluster.nix {
    inherit pkgs;
    inherit (pkgs) lib;
  };
in
pkgs.testers.runNixOSTest {
  name = "slurm-on-cephfs-job-roundtrip";

  nodes = {
    storage_a = cluster.storageANode;
    storage_b = cluster.storageBNode;
    storage_c = cluster.storageCNode;
    compute_1 = cluster.mkComputeNode {
      ip = cluster.cfg.compute1Ip;
      hostName = "compute-1";
    };
    compute_2 = cluster.mkComputeNode {
      ip = cluster.cfg.compute2Ip;
      hostName = "compute-2";
    };
  };

  testScript = ''
    ${cluster.bootstrapScript}

    with subtest("storage_c submits an sbatch job that writes to cephfs"):
        out = storage_c.succeed(
            "sbatch --no-requeue --ntasks=1 --time=5 "
            "--output=/mnt/ceph/job-output-%j.txt "
            "--wrap='echo cephfs-roundtrip-ok'"
        ).strip()
        assert "Submitted batch job" in out, f"sbatch failed: {out!r}"
        job_id = out.split()[-1]

    with subtest("output file appears on cephfs with expected content"):
        storage_c.wait_until_succeeds(
            f"ls /mnt/ceph/job-output-{job_id}.txt", timeout=180
        )
        v = storage_c.succeed(
            f"cat /mnt/ceph/job-output-{job_id}.txt"
        ).strip()
        assert v == "cephfs-roundtrip-ok", (
            f"unexpected job output: {v!r}"
        )
        print("INVARIANT HELD: sbatch job ran on a compute node + "
              "wrote output to cephfs visible on slurmctld node")
  '';
}
