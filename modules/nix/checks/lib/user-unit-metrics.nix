{
  pkgs,
  ...
}:
let
  metricsFile = "/var/lib/prometheus-node-exporter-textfiles/fleet-user-units.prom";
in
pkgs.testers.runNixOSTest {
  name = "user-unit-metrics";

  nodes.machine =
    { ... }:
    {
      imports = [ ../../../common/node-exporter.nix ];
      _module.args = {
        host = {
          id = "machine";
          ownership.owner = "owner";
          monitoring = {
            enabled = true;
            exporters = [ "node" ];
            scrape_targets = [ ];
          };
        };
        cluster.users.owner.system_account = {
          username = "alice";
          uid = 1000;
        };
      };

      users.users = {
        alice = {
          isNormalUser = true;
          uid = 1000;
          linger = true;
        };
        bob = {
          isNormalUser = true;
          uid = 1001;
          linger = true;
        };
      };

      systemd.user.services.broken = {
        wantedBy = [ "default.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.coreutils}/bin/false";
        };
      };

      virtualisation.memorySize = 1024;
    };

  testScript = ''
    import time

    t0 = time.time()
    def stage(msg):
        print(f"\n========== [t+{time.time() - t0:6.1f}s] {msg} ==========")

    def user_systemctl(user, uid, command):
        return (
            f"runuser -u {user} -- env XDG_RUNTIME_DIR=/run/user/{uid} "
            f"systemctl --user {command}"
        )

    def collect():
        machine.succeed("systemctl start fleet-user-unit-metrics.service")
        return machine.succeed("cat ${metricsFile}")

    stage("boot with lingering owner and non-owner managers")
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("user@1000.service")
    machine.wait_for_unit("user@1001.service")
    machine.wait_until_succeeds(user_systemctl("alice", 1000, "is-failed --quiet broken.service"))
    machine.wait_until_succeeds(user_systemctl("bob", 1001, "is-failed --quiet broken.service"))

    stage("INVARIANT 1: owner failures are exported, other users are not")
    metrics = collect()
    expected = 'fleet_user_systemd_unit_failed{host="machine",user="alice",name="broken.service"} 1'
    assert expected in metrics.splitlines(), f"FAIL: owner failure missing: {metrics!r}"
    assert "bob" not in metrics, f"FAIL: non-owner manager exported: {metrics!r}"
    machine.wait_for_unit("prometheus-node-exporter.service")
    machine.wait_for_open_port(9100)
    exported = machine.succeed("curl -fsS http://127.0.0.1:9100/metrics")
    assert 'fleet_user_systemd_unit_failed{host="machine",name="broken.service",user="alice"} 1' in exported, (
        "FAIL: node exporter does not serve the owner failure"
    )

    stage("INVARIANT 2: the collector opens no login session")
    machine.succeed("journalctl --sync")
    sessions = machine.succeed("journalctl --output=cat --no-pager | grep -F -c '(login:session)' || true").strip()
    assert sessions == "0", f"FAIL: collector opened {sessions} PAM login sessions"

    stage("INVARIANT 3: recovered units leave no failure series")
    machine.succeed(user_systemctl("alice", 1000, "reset-failed broken.service"))
    metrics = collect()
    assert "fleet_user_systemd_unit_failed{" not in metrics, f"FAIL: stale failure: {metrics!r}"

    stage("INVARIANT 4: a stopped owner manager is not a collector failure")
    machine.succeed("loginctl disable-linger alice")
    machine.wait_until_fails("systemctl is-active --quiet user@1000.service")
    metrics = collect()
    assert "fleet_user_systemd_unit_failed{" not in metrics, f"FAIL: stopped manager exported: {metrics!r}"

    stage(f"DONE in {time.time() - t0:.1f}s")
    print("USER UNIT METRICS VERIFIED")
  '';
}
