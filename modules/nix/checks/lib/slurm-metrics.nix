{
  pkgs,
  ...
}:
let
  testlib = import ./lib.nix { inherit pkgs; };

  clusterNodes = [
    {
      hostName = "controller";
      cores = 2;
      ramMb = 2048;
    }
    {
      hostName = "compute1";
      cores = 1;
      ramMb = 512;
    }
  ];
in
pkgs.testers.runNixOSTest {
  name = "slurm-metrics";

  nodes.controller =
    { ... }:
    {
      imports = [
        (testlib.mkSlurmMaster {
          hostName = "controller";
          inherit clusterNodes;
        })
        ../../../services/slurm-metrics.nix
      ];
      services.cluster-slurm-metrics.enable = true;
    };

  testScript = ''
    import time

    t0 = time.time()
    def stage(msg):
        print(f"\n========== [t+{time.time() - t0:6.1f}s] {msg} ==========")
    def say(msg):
        print(f"[t+{time.time() - t0:6.1f}s] {msg}")

    stage("boot")
    controller.start()
    controller.wait_for_unit("multi-user.target", timeout=240)

    stage("INVARIANT 1: slurmctld up and responsive")
    controller.wait_for_unit("slurmctld.service", timeout=180)
    sinfo = controller.wait_until_succeeds("sinfo --noheader 2>&1", timeout=120)
    say(f"sinfo: {sinfo.strip()!r}")

    stage("INVARIANT 2: MetricsType is set in the running slurm.conf")
    conf = controller.succeed("scontrol show config | grep -i metric || true")
    say(f"scontrol metric directives: {conf.strip()!r}")
    assert "openmetrics" in conf.lower(), (
        f"FAIL: MetricsType=metrics/openmetrics not present in running config: {conf!r}"
    )

    stage("INVARIANT 3: GET /metrics returns the endpoint catalogue")
    controller.wait_for_open_port(6817, timeout=30)
    catalogue = controller.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:6817/metrics", timeout=60
    )
    say(f"catalogue (first 200 chars): {catalogue[:200]!r}")
    for endpoint in ("/metrics/jobs", "/metrics/nodes", "/metrics/partitions", "/metrics/scheduler"):
        assert endpoint in catalogue, (
            f"FAIL: endpoint {endpoint} not advertised in catalogue: {catalogue!r}"
        )

    stage("INVARIANT 4: GET /metrics/jobs exposes job gauges")
    jobs = controller.succeed("curl -fsS http://127.0.0.1:6817/metrics/jobs")
    for metric in ("slurm_jobs", "slurm_jobs_running", "slurm_jobs_pending"):
        assert metric in jobs, (
            f"FAIL: metric {metric} missing from /metrics/jobs:\n{jobs}"
        )
    assert "# TYPE slurm_jobs gauge" in jobs, (
        f"FAIL: OpenMetrics TYPE comment missing for slurm_jobs:\n{jobs}"
    )
    say(f"/metrics/jobs returned {len(jobs.splitlines())} lines")

    stage("INVARIANT 5: GET /metrics/nodes shows the controller node")
    nodes = controller.succeed("curl -fsS http://127.0.0.1:6817/metrics/nodes")
    assert "slurm_nodes" in nodes, f"FAIL: slurm_nodes missing:\n{nodes}"
    import re
    m = re.search(r"^slurm_nodes\s+(\d+)", nodes, re.MULTILINE)
    assert m is not None, f"FAIL: couldn't parse slurm_nodes value:\n{nodes}"
    total = int(m.group(1))
    assert total >= 1, f"FAIL: slurm_nodes = {total}, expected >= 1"
    say(f"slurm_nodes total = {total}")

    stage("INVARIANT 6: GET /metrics/scheduler exposes scheduler stats")
    sched = controller.succeed("curl -fsS http://127.0.0.1:6817/metrics/scheduler")
    expected_one_of = (
        "slurm_bf_cycle_cnt",
        "slurm_bf_active",
        "slurm_sched_cycle_cnt",
    )
    assert any(m in sched for m in expected_one_of), (
        f"FAIL: none of {expected_one_of} present in /metrics/scheduler:\n{sched}"
    )
    say(f"/metrics/scheduler returned {len(sched.splitlines())} lines")

    stage(f"DONE in {time.time() - t0:.1f}s")
    print("SLURM-METRICS VERIFICATIONS PASSED")
  '';
}
