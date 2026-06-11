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
        monitoring = {
          enabled = true;
          exporters = [ "node" ];
          scrape_targets = [ ];
        };
      };
      worker_a = {
        id = "worker_a";
        state = "provisioned";
        monitoring = {
          enabled = true;
          exporters = [ "node" ];
          scrape_targets = [ ];
        };
      };
      worker_b = {
        id = "worker_b";
        state = "provisioned";
        monitoring = {
          enabled = true;
          exporters = [ "node" ];
          scrape_targets = [ ];
        };
      };
    };
  };

  mkObserver =
    { ... }:
    {
      imports = [
        ../modules/common/node-exporter.nix
        ../modules/services/victoriametrics.nix
        ../modules/services/grafana.nix
      ];
      _module.args = {
        host = {
          id = "observability";
          monitoring = {
            enabled = true;
            exporters = [ "node" ];
            scrape_targets = [ ];
          };
        };
        cluster = testCluster;
      };
      services.cluster-grafana.anonymousViewer = true;

      networking.firewall.enable = false;
      virtualisation = {
        memorySize = 2048;
        cores = 2;
      };

      networking.extraHosts = ''
        192.168.1.1 observability
        192.168.1.2 worker_a
        192.168.1.3 worker_b
      '';
    };

  mkWorker = name: {
    imports = [ ../modules/common/node-exporter.nix ];
    _module.args = {
      host = {
        id = name;
        monitoring = {
          enabled = true;
          exporters = [ "node" ];
          scrape_targets = [ ];
        };
      };
      cluster = testCluster;
    };
    networking.hostName = lib.mkForce name;
    networking.firewall.enable = false;
    virtualisation = {
      memorySize = 1024;
      cores = 1;
    };
    networking.extraHosts = ''
      192.168.1.1 observability
      192.168.1.2 worker_a
      192.168.1.3 worker_b
    '';
  };
in
pkgs.testers.runNixOSTest {
  name = "observability";

  nodes = {
    observability = mkObserver;
    worker_a = _: mkWorker "worker_a";
    worker_b = _: mkWorker "worker_b";
  };

  testScript = ''
    import time
    import json

    t0 = time.time()
    def stage(msg):
        print(f"\n========== [t+{time.time() - t0:6.1f}s] {msg} ==========")
    def say(msg):
        print(f"[t+{time.time() - t0:6.1f}s] {msg}")

    stage("boot all 3 nodes")
    start_all()
    for n, name in [
        (observability, "observability"),
        (worker_a, "worker_a"),
        (worker_b, "worker_b"),
    ]:
        n.wait_for_unit("multi-user.target", timeout=180)
        say(f"{name}: multi-user.target reached")

    stage("INVARIANT 1: node_exporter responds on every host")
    for n, name in [
        (observability, "observability"),
        (worker_a, "worker_a"),
        (worker_b, "worker_b"),
    ]:
        n.wait_for_open_port(9100, timeout=60)
        body = n.succeed("curl -fsS http://127.0.0.1:9100/metrics")
        assert "HELP" in body, f"FAIL: {name} node_exporter not serving metrics"
        assert "node_load1" in body, f"FAIL: {name} missing node_load1 metric"
        say(f"{name}: node_exporter OK ({len(body.splitlines())} metric lines)")

    stage("INVARIANT 2: VictoriaMetrics up and accepting queries")
    observability.wait_for_unit("victoriametrics.service", timeout=120)
    observability.wait_for_open_port(8428, timeout=60)
    health = observability.succeed("curl -fsS http://127.0.0.1:8428/health")
    say(f"VM health: {health.strip()}")
    assert "OK" in health, f"FAIL: VictoriaMetrics health != OK: {health!r}"

    stage("INVARIANT 3: VictoriaMetrics scrapes both workers within 60s")
    def query_up(target_host):
        url = (
            f"http://127.0.0.1:8428/api/v1/query"
            f"?query=up%7Binstance%3D%22{target_host}%3A9100%22%7D"
        )
        out = observability.succeed(f"curl -fsS '{url}'")
        return json.loads(out)

    for target in ("observability", "worker_a", "worker_b"):
        def check():
            data = query_up(target)
            results = data.get("data", {}).get("result", [])
            return results and results[0]["value"][1] == "1"
        deadline = time.time() + 120
        while time.time() < deadline:
            if check():
                say(f"OK scrape from {target} returned up=1")
                break
            time.sleep(2)
        else:
            data = query_up(target)
            print(f"FAIL: never saw up=1 for {target}; last response: {json.dumps(data)}")
            targets_dump = observability.succeed(
                "curl -fsS http://127.0.0.1:8428/api/v1/targets || true"
            )
            print(targets_dump)
            raise Exception(f"target {target} never came up")

    stage("INVARIANT 4: Grafana serves and the VM datasource is healthy")
    observability.wait_for_unit("grafana.service", timeout=120)
    observability.wait_for_open_port(3000, timeout=60)
    ds_json = observability.succeed(
        "curl -fsS -u admin:admin "
        "'http://127.0.0.1:3000/api/datasources/name/VictoriaMetrics'"
    )
    ds = json.loads(ds_json)
    ds_id = ds["id"]
    ds_uid = ds["uid"]
    say(f"Grafana datasource id={ds_id} uid={ds_uid}")
    assert ds["type"] == "prometheus", f"FAIL: datasource type != prometheus: {ds!r}"

    stage("INVARIANT 5: node_load1 queryable through both VM and Grafana")
    load_direct = observability.succeed(
        "curl -fsS 'http://127.0.0.1:8428/api/v1/query?query=node_load1'"
    )
    load_doc = json.loads(load_direct)
    assert load_doc.get("status") == "success", f"FAIL: VM query status != success: {load_doc}"
    assert load_doc["data"]["result"], "FAIL: VM returned no node_load1 series"
    say(f"VM node_load1 series count: {len(load_doc['data']['result'])}")

    load_grafana = observability.succeed(
        f"curl -fsS -u admin:admin "
        f"'http://127.0.0.1:3000/api/datasources/proxy/uid/{ds_uid}/api/v1/query?query=node_load1'"
    )
    say(f"Grafana proxied query (first 200 chars): {load_grafana[:200]}")
    proxied_doc = json.loads(load_grafana)
    assert proxied_doc.get("status") == "success", f"FAIL: Grafana proxy did not return success: {proxied_doc!r}"
    assert proxied_doc["data"]["result"], "FAIL: Grafana proxy returned empty series"
    say(f"Grafana proxy series count: {len(proxied_doc['data']['result'])}")

    stage(f"DONE in {time.time() - t0:.1f}s")
    print("OBSERVABILITY VERIFICATIONS PASSED")
  '';
}
