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
  name = "slurm-on-cephfs-output-readable-from-other-compute";

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

    with subtest("submit a job pinned to compute-1"):
        out = storage_c.succeed(
            "sbatch --no-requeue --ntasks=1 --time=5 "
            "--nodelist=compute-1 "
            "--output=/mnt/ceph/cross-compute-%j.txt "
            "--wrap='echo from-compute-1'"
        ).strip()
        assert "Submitted batch job" in out, f"sbatch failed: {out!r}"
        job_id = out.split()[-1]

    with subtest("output file appears on cephfs"):
        storage_c.wait_until_succeeds(
            f"ls /mnt/ceph/cross-compute-{job_id}.txt", timeout=180
        )

    with subtest("compute_2 (other node) reads same output via cephfs"):
        v = compute_2.wait_until_succeeds(
            f"cat /mnt/ceph/cross-compute-{job_id}.txt", timeout=60
        ).strip()
        assert v == "from-compute-1", (
            f"compute_2 saw {v!r} instead of the expected output "
            f"-- cephfs coherence broken under slurm workload"
        )
        print("INVARIANT HELD: cephfs output written by a job on one "
              "compute node is readable from a DIFFERENT compute node")
  '';
}
