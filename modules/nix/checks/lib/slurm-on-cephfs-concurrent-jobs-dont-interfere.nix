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
  name = "slurm-on-cephfs-concurrent-jobs-dont-interfere";

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

    with subtest("submit 4 concurrent jobs each writing its own file"):
        job_ids = []
        for i in range(4):
            out = storage_c.succeed(
                f"sbatch --no-requeue --ntasks=1 --time=5 "
                f"--output=/mnt/ceph/concurrent-{i}-%j.txt "
                f"--wrap='echo payload-{i}'"
            ).strip()
            assert "Submitted batch job" in out, f"sbatch failed: {out!r}"
            job_ids.append((i, out.split()[-1]))

    with subtest("all 4 output files exist with the right per-job payload"):
        for i, job_id in job_ids:
            storage_c.wait_until_succeeds(
                f"ls /mnt/ceph/concurrent-{i}-{job_id}.txt", timeout=180
            )
            v = storage_c.succeed(
                f"cat /mnt/ceph/concurrent-{i}-{job_id}.txt"
            ).strip()
            assert v == f"payload-{i}", (
                f"job {i} (job_id {job_id}) output corrupted: got {v!r}, "
                f"expected 'payload-{i}'. Possible cross-contamination "
                f"with another concurrent job's output."
            )
        print(f"INVARIANT HELD: {len(job_ids)} concurrent jobs each "
              f"wrote their own correct payload to cephfs with no "
              f"cross-contamination")
  '';
}
