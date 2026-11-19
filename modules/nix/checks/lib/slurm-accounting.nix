{ pkgs, ... }:
let
  testlib = import ./lib.nix { inherit pkgs; };

  clusterNodes = [
    {
      hostName = "controller";
      sockets = 1;
      coresPerSocket = 2;
      threadsPerCore = 1;
      ramMb = 2048;
    }
    {
      hostName = "compute1";
      sockets = 1;
      coresPerSocket = 2;
      threadsPerCore = 1;
      ramMb = 1536;
    }
  ];
in
pkgs.testers.runNixOSTest {
  name = "slurm-accounting";

  nodes = {
    controller = testlib.mkSlurmMaster {
      hostName = "controller";
      inherit clusterNodes;
    };
    compute1 = testlib.mkSlurmCompute {
      hostName = "compute1";
      masterHostname = "controller";
      inherit clusterNodes;
      adopt = false;
    };
    login = testlib.mkSlurmSubmit {
      hostName = "login";
      masterHostname = "controller";
    };
  };

  testScript = ''
    start_all()
    controller.wait_for_unit("slurmdbd.service")
    controller.wait_for_unit("slurmctld.service")
    compute1.wait_for_unit("slurmd.service")
    controller.wait_until_succeeds("sinfo -h -N -n compute1 -o '%T' | grep -qx idle", timeout=120)

    with subtest("the accounting database accepts no network connections"):
        controller.wait_for_open_port(6819)
        controller.fail("ss -Hltn 'sport = :3306' | grep -q .")

    with subtest("slurmctld registers the cluster in the accounting database"):
        controller.wait_until_succeeds(
            "sacctmgr -n -P list cluster format=cluster | grep -qx test-cluster", timeout=120
        )

    job = login.succeed(
        "sbatch --parsable --acctg-freq=task=1 --output=/dev/null --wrap 'sleep 3'"
    ).strip()

    with subtest("every host reads the finished job from slurmdbd"):
        for machine in (controller, compute1, login):
            machine.wait_until_succeeds(
                f"sacct -n -P -X -j {job} -o Cluster,State | grep -qx 'test-cluster|COMPLETED'",
                timeout=120,
            )

    with subtest("the compute node records the job usage"):
        max_rss = login.succeed(f"sacct -n -P -j {job}.batch -o MaxRSS").strip()
        assert max_rss not in ("", "0"), f"no MaxRSS for {job}.batch: {max_rss!r}"
  '';
}
