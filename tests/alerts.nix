{
  pkgs,
  self,
  ...
}:
let
  inherit (pkgs) lib;

  testCluster = {
    hosts = {
      obs = {
        id = "obs";
        state = "provisioned";
        monitoring = {
          enabled = true;
          exporters = [ "node" ];
          scrape_targets = [ ];
        };
      };
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "alerts";

  nodes.obs =
    { ... }:
    {
      imports = [
        ../modules/common/node-exporter.nix
        ../modules/services/victoriametrics.nix
        ../modules/services/vmalert.nix
        ../modules/services/alertmanager.nix
      ];
      _module.args = {
        inherit self;
        host = {
          id = "obs";
          monitoring = {
            enabled = true;
            exporters = [ "node" ];
            scrape_targets = [ ];
          };
        };
        cluster = testCluster;
      };

      services.cluster-alertmanager = {
        webhookUrl = "http://127.0.0.1:9999/alert";
        groupWait = "5s";
        groupInterval = "10s";
        repeatInterval = "30s";
      };

      services.cluster-vmalert.ruleDir = ./data/alerts;
      services.cluster-vmalert.evaluationInterval = "5s";

      networking.firewall.enable = lib.mkForce false;
      networking.extraHosts = ''
        192.168.1.1 obs
      '';
      virtualisation = {
        memorySize = 2048;
        cores = 2;
      };

      environment.systemPackages = [ pkgs.python3 ];
    };

  testScript = ''
    import time
    import json

    t0 = time.time()
    def stage(msg):
        print(f"\n========== [t+{time.time() - t0:6.1f}s] {msg} ==========")
    def say(msg):
        print(f"[t+{time.time() - t0:6.1f}s] {msg}")

    stage("boot")
    obs.start()
    obs.wait_for_unit("multi-user.target", timeout=180)

    stage("launch capture http server on :9999 -> /tmp/alert.json")
    obs.succeed(
        "cat > /tmp/capture.py <<'PY'\n"
        "import http.server, json, sys\n"
        "class H(http.server.BaseHTTPRequestHandler):\n"
        "  def do_POST(self):\n"
        "    n = int(self.headers.get('Content-Length','0'))\n"
        "    body = self.rfile.read(n)\n"
        "    open('/tmp/alert.json','ab').write(body + b'\\n')\n"
        "    self.send_response(200); self.end_headers()\n"
        "  def log_message(self,*a,**k): pass\n"
        "http.server.HTTPServer(('127.0.0.1',9999), H).serve_forever()\n"
        "PY"
    )
    obs.succeed("rm -f /tmp/alert.json")
    obs.succeed("systemd-run --unit alert-capture python3 /tmp/capture.py")
    obs.wait_for_open_port(9999, timeout=30)
    say("capture server listening")

    stage("INVARIANT 1: vmalert lists the InstanceDown rule")
    obs.wait_for_unit("vmalert-default.service", timeout=120)
    obs.wait_for_open_port(8880, timeout=60)
    rules_json = obs.succeed("curl -fsS http://127.0.0.1:8880/api/v1/rules")
    rules = json.loads(rules_json)
    found_names = []
    for g in rules.get("data", {}).get("groups", []):
        for r in g.get("rules", []):
            if r.get("name") or r.get("alert"):
                found_names.append(r.get("name") or r.get("alert"))
    say(f"vmalert rules: {found_names}")
    assert "InstanceDown" in found_names, (
        f"FAIL: InstanceDown rule not loaded; have {found_names!r}"
    )

    stage("INVARIANT 2: no alerts firing while node_exporter is up")
    obs.wait_for_unit("prometheus-node-exporter.service", timeout=60)
    obs.wait_for_unit("victoriametrics.service", timeout=120)
    obs.wait_for_open_port(8428, timeout=60)
    deadline = time.time() + 60
    while time.time() < deadline:
        alerts_json = obs.succeed("curl -fsS http://127.0.0.1:8880/api/v1/alerts")
        alerts = json.loads(alerts_json).get("data", {}).get("alerts", [])
        firing = [a for a in alerts if a.get("state") == "firing"]
        if firing:
            raise Exception(f"FAIL: alert firing while node_exporter is up: {firing!r}")
        time.sleep(5)
    say("no alerts firing while target is healthy")

    stage("INVARIANT 3: stop node_exporter -> VM observes up == 0")
    obs.succeed("systemctl stop prometheus-node-exporter.service")
    say("node_exporter stopped")
    deadline = time.time() + 90
    saw_down = False
    while time.time() < deadline:
        resp = obs.succeed(
            "curl -fsS -G "
            "--data-urlencode 'query=up{job=\"fleet-node\"}' "
            "http://127.0.0.1:8428/api/v1/query"
        )
        data = json.loads(resp).get("data", {}).get("result", [])
        zeros = [r for r in data if r.get("value", [None, "1"])[1] == "0"]
        if zeros:
            saw_down = True
            break
        time.sleep(5)
    assert saw_down, "FAIL: VictoriaMetrics never observed up == 0"
    say("VM observed up == 0")

    stage("INVARIANT 4: vmalert transitions InstanceDown -> firing")
    deadline = time.time() + 120
    fired = None
    while time.time() < deadline:
        alerts_json = obs.succeed("curl -fsS http://127.0.0.1:8880/api/v1/alerts")
        alerts = json.loads(alerts_json).get("data", {}).get("alerts", [])
        for a in alerts:
            if a.get("name") == "InstanceDown" and a.get("state") == "firing":
                fired = a
                break
        if fired:
            break
        time.sleep(5)
    assert fired is not None, (
        f"FAIL: InstanceDown never reached firing; last alerts={alerts!r}"
    )
    say(f"InstanceDown firing: labels={fired.get('labels')!r}")

    stage("INVARIANT 5: alertmanager delivers webhook to capture server")
    deadline = time.time() + 90
    payload = None
    while time.time() < deadline:
        rc, out = obs.execute("test -s /tmp/alert.json && cat /tmp/alert.json")
        if rc == 0 and out.strip():
            for line in out.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    candidate = json.loads(line)
                except json.JSONDecodeError:
                    continue
                names = [
                    a.get("labels", {}).get("alertname")
                    for a in candidate.get("alerts", [])
                ]
                if "InstanceDown" in names:
                    payload = candidate
                    break
        if payload:
            break
        time.sleep(5)

    if payload is None:
        say("DIAGNOSTIC: alertmanager active alerts:")
        print(obs.succeed(
            "curl -fsS http://127.0.0.1:9093/api/v2/alerts || true"
        ))
        say("DIAGNOSTIC: capture file dump:")
        rc, dump = obs.execute("cat /tmp/alert.json 2>/dev/null || true")
        print(dump)
        raise Exception("FAIL: capture server never received InstanceDown payload")

    say(f"webhook payload status={payload.get('status')!r} receiver={payload.get('receiver')!r}")
    assert payload.get("status") == "firing", (
        f"FAIL: webhook status != firing: {payload!r}"
    )
    matching = [
        a for a in payload.get("alerts", [])
        if a.get("labels", {}).get("alertname") == "InstanceDown"
    ]
    assert matching, f"FAIL: no InstanceDown alert in payload: {payload!r}"
    assert matching[0].get("labels", {}).get("severity") == "critical", (
        f"FAIL: severity label not propagated: {matching[0]!r}"
    )

    stage(f"DONE in {time.time() - t0:.1f}s")
    print("ALERTS VERIFICATIONS PASSED")
  '';
}
