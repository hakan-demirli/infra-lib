{
  pkgs,
  ...
}:
let
  inherit (pkgs) lib;

  testCluster = {
    hosts = {
      observability = {
        id = "observability";
        state = "provisioned";
        roles = [ "mgmt-observability" ];
        monitoring = {
          enabled = true;
          exporters = [ "node" ];
          scrape_targets = [ ];
        };
      };
      worker = {
        id = "worker";
        state = "provisioned";
        roles = [ "compute" ];
        monitoring = {
          enabled = true;
          exporters = [ "node" ];
          scrape_targets = [ ];
        };
      };
    };
  };

  hostsFile = ''
    192.168.1.1 observability
    192.168.1.2 worker
  '';
in
pkgs.testers.runNixOSTest {
  name = "logs";

  nodes = {
    observability =
      { ... }:
      {
        imports = [
          ../../../common/node-exporter.nix
          ../../../common/vector-shipper.nix
          ../../../services/victorialogs.nix
        ];
        _module.args = {
          host = {
            id = "observability";
            roles = [ "mgmt-observability" ];
            monitoring = {
              enabled = true;
              exporters = [ "node" ];
              scrape_targets = [ ];
            };
          };
          cluster = testCluster;
        };
        networking.firewall.enable = lib.mkForce false;
        networking.extraHosts = hostsFile;
        virtualisation = {
          memorySize = 1536;
          cores = 2;
        };
      };

    worker =
      { ... }:
      {
        imports = [
          ../../../common/node-exporter.nix
          ../../../common/vector-shipper.nix
        ];
        _module.args = {
          host = {
            id = "worker";
            roles = [ "compute" ];
            monitoring = {
              enabled = true;
              exporters = [ "node" ];
              scrape_targets = [ ];
            };
          };
          cluster = testCluster;
        };
        networking.firewall.enable = lib.mkForce false;
        networking.extraHosts = hostsFile;
        virtualisation = {
          memorySize = 1024;
          cores = 1;
        };
      };
  };

  testScript = ''
    import time
    import json
    import uuid

    t0 = time.time()
    def stage(msg):
        print(f"\n========== [t+{time.time() - t0:6.1f}s] {msg} ==========")
    def say(msg):
        print(f"[t+{time.time() - t0:6.1f}s] {msg}")

    stage("boot")
    start_all()
    observability.wait_for_unit("multi-user.target", timeout=180)
    worker.wait_for_unit("multi-user.target", timeout=180)
    say("both nodes reached multi-user.target")

    stage("INVARIANT 1: VictoriaLogs serves")
    observability.wait_for_unit("victorialogs.service", timeout=120)
    observability.wait_for_open_port(9428, timeout=60)
    health = observability.succeed(
        "curl -fsS -G "
        "--data-urlencode 'query=*' "
        "--data-urlencode 'limit=1' "
        "http://127.0.0.1:9428/select/logsql/query"
    )
    say(f"VL select probe (first 80 chars): {health[:80]!r}")

    stage("INVARIANT 5: shipper NOT enabled on observability host")
    rc, _ = observability.execute("systemctl is-enabled vector.service")
    assert rc != 0, "FAIL: vector shipper is enabled on the obs host"
    say("OK: vector shipper not enabled on observability")

    stage("INVARIANT 2: worker runs vector shipper")
    worker.wait_for_unit("vector.service", timeout=120)
    say("worker: vector.service active")

    stage("INVARIANT 3: marker injected on worker shows up centrally")
    marker = f"e2e-logs-marker-{uuid.uuid4().hex[:12]}"
    worker.succeed(f"logger -t e2e-test '{marker}'")
    say(f"injected marker on worker: {marker}")

    deadline = time.time() + 120
    found = None
    while time.time() < deadline:
        out = observability.succeed(
            "curl -fsS -G "
            f"--data-urlencode 'query={marker}' "
            "--data-urlencode 'limit=5' "
            "http://127.0.0.1:9428/select/logsql/query"
        )
        lines = [ln for ln in out.splitlines() if ln.strip()]
        if lines:
            found = json.loads(lines[0])
            break
        time.sleep(3)

    if found is None:
        print(observability.succeed(
            "curl -fsS http://127.0.0.1:9428/metrics | grep -E "
            "'^vl_(rows_ingested_total|streams_created_total|active_streams|http_request_errors_total)' || true"
        ))
        print(worker.succeed("journalctl -u vector --no-pager -n 60 || true"))
        raise Exception(f"FAIL: marker {marker} not found in VictoriaLogs after 120s")

    say(f"found marker entry: {json.dumps(found)[:200]}")

    stage("INVARIANT 4: stream fields populated (host, unit)")
    assert found.get("host") == "worker", (
        f"FAIL: stream field 'host' != 'worker': {found.get('host')!r}"
    )
    assert "unit" in found, f"FAIL: stream field 'unit' missing: {found!r}"
    say(f"stream fields: host={found.get('host')!r} unit={found.get('unit')!r}")

    stage(f"DONE in {time.time() - t0:.1f}s")
    print("LOGS VERIFICATIONS PASSED")
  '';
}
