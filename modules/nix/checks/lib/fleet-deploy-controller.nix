{
  pkgs,
  self,
  inputs,
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;
  repo = "/var/lib/fleet-repo";
  hostIds = [
    "canary"
    "guest-canary"
    "held-canary"
    "slurmctl"
    "compute"
    "remote"
    "expired"
  ];

  flake = pkgs.writeText "flake.nix" ''
    {
      outputs =
        { self }:
        let
          plan = import ./plan.nix;
        in
        {
          lib.intent.deployPlan = plan;
          nixosConfigurations = builtins.mapAttrs (name: _: {
            config.system.build.toplevel = derivation {
              name = "nixos-system-''${name}-test";
              system = "${system}";
              builder = "/bin/sh";
              args = [ "-c" "echo ''${self.rev} > $out" ];
            };
          }) plan.hosts;
        };
    }
  '';
  plan = pkgs.writeText "plan.nix" ''
    let
      host = attrs: { wave = 1; hold = null; system = "${system}"; after = [ ]; trusted = true; cache = true; } // attrs;
    in
    {
      controller = "controller";
      hosts = {
        canary = host { wave = 0; };
        guest-canary = host { wave = 0; trusted = false; cache = false; };
        held-canary = host { wave = 0; hold = { reason = "tapeout"; until = null; }; };
        slurmctl = host { };
        compute = host { after = [ "slurmctl" ]; };
        remote = host { cache = false; };
        expired = host { hold = { reason = "over"; until = "2000-01-01"; }; };
      };
    }
  '';
in
pkgs.testers.runNixOSTest {
  name = "fleet-deploy-controller";

  nodes.controller = {
    imports = [
      inputs.impermanence.nixosModules.impermanence
      (self + "/modules/services/fleet-deploy-controller.nix")
    ];
    _module.args.host = {
      id = "controller";
      deploy.controller = true;
      impermanence.enable = false;
    };

    services.fleet-deploy-controller = {
      repository = repo;
      flake = "git+file://${repo}";
      metricsUrl = "http://127.0.0.1:8428";
    };

    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      flake-registry = "";
      substituters = pkgs.lib.mkForce [ ];
    };

    services.victoriametrics = {
      enable = true;
      listenAddress = "127.0.0.1:8428";
      extraOptions = [
        "-search.latencyOffset=0s"
        "-search.disableCache"
      ];
    };
    systemd.tmpfiles.rules = [ "d /var/lib/prometheus-node-exporter-textfiles 0755 root root -" ];

    environment.systemPackages = [
      pkgs.git
      pkgs.jq
    ];
    virtualisation.memorySize = 2048;
  };

  testScript = ''
    import json
    import time

    hosts = ${builtins.toJSON hostIds}
    markers = iter(range(1, 1000))

    def commit(message):
        controller.succeed(
            "runuser -u fleet-deploy -- git -C ${repo} "
            f"-c user.name=ci -c user.email=ci@example commit --allow-empty -q -m {message}"
        )
        return controller.succeed("runuser -u fleet-deploy -- git -C ${repo} rev-parse HEAD").strip()

    def host(name, revision, hours, failed_units=0, upgrade=None, down=False):
        instance = f'instance="{name}.example:9100"'
        lines = [
            f'fleet_nixos_system_info{{{instance},host="{name}",revision="{revision}",revision_kind="git"}} 1',
            f'fleet_nixos_system_activation_timestamp_seconds{{{instance},host="{name}"}} {int(time.time() - hours * 3600)}',
            f'node_systemd_unit_state{{{instance},name="probe.service",state="failed"}} {failed_units}',
            f'up{{{instance},job="fleet-node",always_on="true"}} {0 if down else 1}',
        ]
        if upgrade is not None:
            lines.append(f'fleet_upgrade_state{{{instance},host="{name}",state="failed",reason="switch",revision="{upgrade}"}} 1')
        return lines

    def run(*series):
        if controller.succeed("systemctl is-active victoriametrics.service || true").strip() == "active":
            controller.succeed(
                "curl -fsS --data-urlencode 'match[]={__name__=~\".+\"}' http://127.0.0.1:8428/api/v1/admin/tsdb/delete_series"
            )
            marker = next(markers)
            payload = "\n".join([line for group in series for line in group] + [f"fleet_test_import {marker}"])
            controller.succeed(f"cat > /tmp/series.prom <<'EOF'\n{payload}\nEOF")
            controller.succeed("curl -fsS --data-binary @/tmp/series.prom http://127.0.0.1:8428/api/v1/import/prometheus")
            controller.wait_until_succeeds(
                "curl -fsS --get --data-urlencode 'query=fleet_test_import' http://127.0.0.1:8428/api/v1/query"
                f" | jq -e '.data.result[0].value[1] == \"{marker}\"'",
                timeout=30,
            )
        controller.succeed("systemctl start fleet-deploy-controller.service")
        return json.loads(controller.succeed("curl -fsS http://127.0.0.1:5102/plan.json"))

    def planned(plan, name, revision):
        entry = plan["hosts"][name]
        assert entry["state"] == "planned" and entry["revision"] == revision, (name, entry)
        return entry["toplevel"]

    def built(plan, name, revision):
        assert controller.succeed(f"cat {planned(plan, name, revision)}").strip() == revision

    def waiting(plan, name, reason):
        entry = plan["hosts"][name]
        assert entry["state"] == "waiting" and entry["reason"] == reason, (name, entry)

    controller.wait_for_unit("victoriametrics.service")
    controller.wait_for_open_port(8428)
    controller.succeed(
        "install -d -o fleet-deploy -g fleet-deploy ${repo}",
        "runuser -u fleet-deploy -- git -C ${repo} init -q -b deploy",
        "install -o fleet-deploy -m 0644 ${flake} ${repo}/flake.nix",
        "install -o fleet-deploy -m 0644 ${plan} ${repo}/plan.nix",
        "runuser -u fleet-deploy -- git -C ${repo} add flake.nix plan.nix",
    )
    first = commit("first")

    with subtest("the first wave takes the deploy revision; untrusted canaries do not open the gate"):
        plan = run(host("canary", first, 1), host("guest-canary", first, 7))
        assert plan["deploy_revision"] == first and plan["history"] == [first], plan
        built(plan, "canary", first)
        assert plan["hosts"]["held-canary"]["state"] == "held", plan
        waiting(plan, "slurmctl", "gate")
        assert plan["waves"]["1"]["state"] == "soaking", plan

    with subtest("a soaked trusted canary opens the next wave; untrusted failures do not count"):
        plan = run(host("canary", first, 7), host("guest-canary", first, 7, failed_units=1))
        assert plan["waves"]["1"]["state"] == "passed", plan
        built(plan, "slurmctl", first)
        built(plan, "expired", first)
        remote = planned(plan, "remote", first)
        controller.fail(f"test -e {remote}")
        waiting(plan, "compute", "dependency")

    with subtest("Slurm nodes follow once their controller runs the revision"):
        built(run(host("canary", first, 8), host("slurmctl", first, 0)), "compute", first)

    second = commit("second")
    third = commit("third")
    with subtest("the next wave takes the newest soaked revision even when deploy moved on"):
        plan = run(host("canary", second, 7), host("slurmctl", first, 1))
        assert plan["deploy_revision"] == third, plan
        built(plan, "canary", third)
        built(plan, "slurmctl", second)
        waiting(plan, "compute", "dependency")

    with subtest("failed units, a failed upgrade or a down canary block the next wave"):
        for canary in [
            host("canary", third, 7, failed_units=1),
            host("canary", second, 7, upgrade=third),
            host("canary", third, 7, down=True),
        ]:
            plan = run(canary, host("slurmctl", second, 1))
            assert plan["waves"]["1"]["state"] == "blocked", plan
            assert plan["waves"]["1"]["approved"] == second, plan
            built(plan, "compute", second)
        prom = controller.succeed("cat /var/lib/prometheus-node-exporter-textfiles/fleet-deploy.prom")
        assert f'fleet_deploy_wave_info{{wave="1",revision="{second}",candidate="{third}",state="blocked"}} 1' in prom, prom

    with subtest("a Slurm controller that already runs a newer revision satisfies its nodes"):
        built(run(host("canary", third, 1), host("slurmctl", third, 1)), "compute", second)

    with subtest("unreachable metrics hold the gate and Slurm dependents"):
        controller.succeed("systemctl stop victoriametrics.service")
        plan = run()
        assert plan["waves"]["1"]["state"] == "metrics-unreachable", plan
        built(plan, "slurmctl", second)
        waiting(plan, "compute", "metrics-unreachable")
  '';
}
