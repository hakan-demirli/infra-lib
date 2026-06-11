{
  pkgs,
  ...
}:
let
  inherit (pkgs) lib;
in
pkgs.testers.runNixOSTest {
  name = "hardware-health";

  nodes = {
    hwhost =
      { ... }:
      {
        imports = [
          ../../../common/node-exporter.nix
          ../../../common/smartctl-exporter.nix
          ../../../common/ipmi-exporter.nix
        ];
        _module.args.host = {
          id = "hwhost";
          monitoring = {
            enabled = true;
            exporters = [
              "node"
              "smartctl"
              "ipmi"
            ];
            scrape_targets = [ ];
          };
        };
        networking.firewall.enable = lib.mkForce false;
        virtualisation = {
          memorySize = 1024;
          cores = 2;
        };
      };

    control =
      { ... }:
      {
        imports = [
          ../../../common/node-exporter.nix
          ../../../common/smartctl-exporter.nix
          ../../../common/ipmi-exporter.nix
        ];
        _module.args.host = {
          id = "control";
          monitoring = {
            enabled = true;
            exporters = [ "node" ];
            scrape_targets = [ ];
          };
        };
        networking.firewall.enable = lib.mkForce false;
        virtualisation = {
          memorySize = 512;
          cores = 1;
        };
      };
  };

  testScript = ''
    import time

    t0 = time.time()
    def stage(msg):
        print(f"\n========== [t+{time.time() - t0:6.1f}s] {msg} ==========")
    def say(msg):
        print(f"[t+{time.time() - t0:6.1f}s] {msg}")

    stage("boot")
    start_all()
    hwhost.wait_for_unit("multi-user.target", timeout=180)
    control.wait_for_unit("multi-user.target", timeout=180)

    stage("INVARIANT 1: smartctl_exporter on :9633 (hwhost)")
    hwhost.wait_for_unit("prometheus-smartctl-exporter.service", timeout=60)
    hwhost.wait_for_open_port(9633, timeout=60)
    smart_metrics = hwhost.succeed("curl -fsS http://127.0.0.1:9633/metrics")
    assert "smartctl_exporter_build_info" in smart_metrics, (
        "FAIL: smartctl_exporter_build_info not in /metrics"
    )
    say("smartctl_exporter responding")

    stage("INVARIANT 2: ipmi_exporter on :9290 (hwhost)")
    deadline = time.time() + 120
    while time.time() < deadline:
        rc, _ = hwhost.execute(
            "systemctl is-active --quiet prometheus-ipmi-exporter.service"
        )
        if rc == 0:
            break
        time.sleep(3)
    rc, st = hwhost.execute(
        "systemctl is-active prometheus-ipmi-exporter.service"
    )
    say(f"ipmi exporter unit state: {st.strip()!r}")
    hwhost.wait_for_open_port(9290, timeout=60)
    ipmi_metrics = hwhost.succeed("curl -fsS http://127.0.0.1:9290/metrics")
    assert "ipmi_up" in ipmi_metrics, (
        "FAIL: ipmi_up family not in /metrics (exporter not serving)"
    )
    say("ipmi_exporter responding")

    stage("INVARIANT 3: node_exporter still up on :9100 (hwhost)")
    hwhost.wait_for_unit("prometheus-node-exporter.service", timeout=60)
    hwhost.wait_for_open_port(9100, timeout=30)
    node_metrics = hwhost.succeed("curl -fsS http://127.0.0.1:9100/metrics")
    assert "node_load1" in node_metrics, "FAIL: node_load1 missing"
    say("node_exporter still healthy")

    stage("INVARIANT 4: control host has node-only; 9633/9290 closed")
    control.wait_for_unit("prometheus-node-exporter.service", timeout=60)
    control.wait_for_open_port(9100, timeout=30)
    rc, _ = control.execute(
        "systemctl is-enabled prometheus-smartctl-exporter.service"
    )
    assert rc != 0, "FAIL: smartctl exporter is enabled on control host"
    rc, _ = control.execute(
        "systemctl is-enabled prometheus-ipmi-exporter.service"
    )
    assert rc != 0, "FAIL: ipmi exporter is enabled on control host"
    rc, _ = control.execute(
        "timeout 1 bash -c '</dev/tcp/127.0.0.1/9633' 2>/dev/null"
    )
    assert rc != 0, "FAIL: port 9633 is open on control host"
    rc, _ = control.execute(
        "timeout 1 bash -c '</dev/tcp/127.0.0.1/9290' 2>/dev/null"
    )
    assert rc != 0, "FAIL: port 9290 is open on control host"
    say("control host: only node_exporter exposed; gate works")

    stage("INVARIANT 5: operator CLIs in PATH on hwhost")
    hwhost.succeed("command -v smartctl")
    hwhost.succeed("command -v ipmitool")
    hwhost.succeed("command -v ipmi-sensors")
    say("CLIs present")

    stage(f"DONE in {time.time() - t0:.1f}s")
    print("HARDWARE-HEALTH VERIFICATIONS PASSED")
  '';
}
