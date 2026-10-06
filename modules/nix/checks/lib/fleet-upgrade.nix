{
  pkgs,
  self,
}:
let
  baseRevision = "0000000000000000000000000000000000000001";
  nextRevision = "0000000000000000000000000000000000000002";
  repo = "/var/lib/fleet-repo";
in
pkgs.testers.runNixOSTest {
  name = "fleet-upgrade";

  nodes.machine =
    { lib, ... }:
    {
      imports = [
        (self + "/modules/common/auto-upgrade.nix")
        (self + "/modules/common/node-exporter.nix")
      ];
      _module.args = {
        host = {
          id = "machine";
          ownership.owner = null;
          monitoring = {
            enabled = true;
            exporters = [ "node" ];
            scrape_targets = [ ];
          };
        };
        cluster = {
          deployController = "controller";
          deployableHosts = [ "machine" ];
        };
      };

      cluster.autoUpgrade = {
        enable = true;
        planUrl = "http://127.0.0.1:8000/plan.json";
        flake = "git+file://${repo}";
        healthAttempts = 3;
      };
      system.configurationRevision = baseRevision;

      nix.settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        flake-registry = "";
        sandbox = false;
        substituters = lib.mkForce [ ];
      };

      systemd.services.plan-server = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8000 --bind 127.0.0.1 --directory /srv";
      };
      systemd.tmpfiles.rules = [ "d /srv 0755 root root -" ];

      specialisation = {
        next.configuration = {
          boot.kernelParams = [ "fleet-upgrade-test" ];
          system.configurationRevision = lib.mkForce nextRevision;
        };
        local.configuration.system.configurationRevision = lib.mkForce "${nextRevision}-dirty";
        unreachable.configuration = {
          system.configurationRevision = lib.mkForce nextRevision;
          systemd.services.plan-server.enable = lib.mkForce false;
        };
      };

      environment.systemPackages = [ pkgs.git ];
      virtualisation.memorySize = 2048;
    };

  testScript =
    { nodes, ... }:
    ''
      import json

      base = "${nodes.machine.system.build.toplevel}"
      metrics = "/var/lib/prometheus-node-exporter-textfiles/fleet-upgrade.prom"
      coreutils = "${pkgs.coreutils}/bin"

      def commit(builder):
          flake = f"""
          {{
            outputs = {{ self }}: {{
              nixosConfigurations.machine.config.system.build.toplevel = derivation {{
                name = "nixos-system-machine-generation";
                system = "${pkgs.stdenv.hostPlatform.system}";
                builder = "/bin/sh";
                args = [ "-c" "{builder}; true" ];
              }};
            }};
          }}
          """
          machine.succeed(f"cat > ${repo}/flake.nix <<'EOF'\n{flake}\nEOF")
          machine.succeed(
              "git -C ${repo} add flake.nix",
              "git -C ${repo} -c user.name=ci -c user.email=ci@example commit -q -m generation",
          )
          revision = machine.succeed("git -C ${repo} rev-parse HEAD").strip()
          toplevel = machine.succeed(
              f"nix eval --raw 'git+file://${repo}?rev={revision}#nixosConfigurations.machine.config.system.build.toplevel.outPath'"
          ).strip()
          return revision, toplevel

      def publish(history, **entry):
          plan = {"history": history, "hosts": {"machine": {"state": "planned", "reason": "none", **entry}}}
          machine.succeed(f"cat > /srv/plan.json <<'EOF'\n{json.dumps(plan)}\nEOF")

      def upgrade(expected_state, expected_reason, succeeds=True):
          status, output = machine.execute("systemctl start fleet-upgrade.service 2>&1")
          assert (status == 0) == succeeds, f"status={status}: {output}"
          line = machine.succeed(f"grep '^fleet_upgrade_state' {metrics}")
          assert f'state="{expected_state}",reason="{expected_reason}"' in line, line

      def running(toplevel):
          machine.succeed(f'test "$(readlink -f /run/current-system)" = "$(readlink -f {toplevel})"')

      machine.wait_for_unit("plan-server.service")
      machine.wait_for_open_port(8000)
      machine.succeed("git init -q -b deploy ${repo}")
      boot_id = machine.succeed("cat /proc/sys/kernel/random/boot_id")
      history = ["${nextRevision}", "${baseRevision}"]

      good, good_toplevel = commit(f"{coreutils}/ln -s {base}/specialisation/next $out")
      history.insert(0, good)

      with subtest("the host builds the planned revision and switches to it without a reboot"):
          publish(history, revision=good, toplevel=good_toplevel)
          upgrade("current", "none")
          running(f"{base}/specialisation/next")
          assert machine.succeed("cat /proc/sys/kernel/random/boot_id") == boot_id
          machine.wait_until_succeeds(
              "grep -q 'component=\"kernel-params\"} 1' /var/lib/prometheus-node-exporter-textfiles/fleet-revisions.prom"
          )
          upgrade("current", "none")

      with subtest("holds and waiting plans keep the current generation"):
          publish(history, state="held", reason="inventory", revision=None, toplevel=None)
          upgrade("held", "inventory")
          publish(history, state="waiting", reason="dependency", revision=good, toplevel=None)
          upgrade("waiting", "dependency")
          running(f"{base}/specialisation/next")

      with subtest("a host ahead of its plan is never downgraded"):
          publish(history, revision="${baseRevision}", toplevel=base)
          upgrade("held", "ahead")
          running(f"{base}/specialisation/next")

      with subtest("a plan for another host or with a foreign path is rejected"):
          publish(history, revision=good, toplevel="/nix/store/00000000000000000000000000000000-nixos-system-other-1")
          upgrade("failed", "invalid-plan", succeeds=False)
          publish(history, revision=good, toplevel="/nix/store/00000000000000000000000000000000-nixos-system-machine-1")
          upgrade("failed", "mismatch", succeeds=False)
          running(f"{base}/specialisation/next")

      with subtest("an unreachable plan is reported as offline"):
          machine.succeed("rm /srv/plan.json")
          upgrade("offline", "plan-unreachable")

      with subtest("a revision that is not on the deploy branch is never replaced"):
          publish([good, "${baseRevision}"], revision=good, toplevel=good_toplevel)
          upgrade("held", "local")

      broken, broken_toplevel = commit(
          f"{coreutils}/mkdir -p $out/bin && "
          f"printf '#!/bin/sh\\\\necho attempt >> /tmp/switch-attempts\\\\nexit 1\\\\n' > $out/bin/switch-to-configuration && "
          f"{coreutils}/chmod +x $out/bin/switch-to-configuration"
      )
      history.insert(0, broken)

      with subtest("a failed switch is not repeated for the same generation"):
          publish(history, revision=broken, toplevel=broken_toplevel)
          upgrade("failed", "switch", succeeds=False)
          upgrade("failed", "switch", succeeds=False)
          assert machine.succeed("wc -l < /tmp/switch-attempts").strip() == "1"
          running(f"{base}/specialisation/next")

      cut_off, cut_off_toplevel = commit(f"{coreutils}/ln -s {base}/specialisation/unreachable $out")
      history.insert(0, cut_off)

      with subtest("a generation that loses connectivity is switched back"):
          publish(history, revision=cut_off, toplevel=cut_off_toplevel)
          upgrade("failed", "rollback", succeeds=False)
          running(f"{base}/specialisation/next")
          machine.wait_for_unit("plan-server.service")
          machine.wait_for_open_port(8000)
          upgrade("failed", "rollback", succeeds=False)
          running(f"{base}/specialisation/next")

      with subtest("a dirty generation is never replaced"):
          machine.succeed(f"{base}/specialisation/local/bin/switch-to-configuration test")
          publish(history, revision=good, toplevel=good_toplevel)
          upgrade("held", "local")
          running(f"{base}/specialisation/local")

      assert machine.succeed("cat /proc/sys/kernel/random/boot_id") == boot_id
    '';
}
