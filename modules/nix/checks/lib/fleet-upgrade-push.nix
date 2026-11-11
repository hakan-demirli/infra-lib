{
  pkgs,
  self,
}:
let
  baseRevision = "0000000000000000000000000000000000000001";
  nextRevision = "0000000000000000000000000000000000000002";
  repo = "/var/lib/fleet-repo";

  pushKey = pkgs.runCommand "fleet-push-test-key" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir $out
    ssh-keygen -q -t ed25519 -N "" -C controller@test -f $out/id_ed25519
  '';
in
pkgs.testers.runNixOSTest {
  name = "fleet-upgrade-push";

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
          deploy.delivery = "push";
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
        pushKeys = [ (lib.fileContents "${pushKey}/id_ed25519.pub") ];
        healthAttempts = 3;
      };
      system.configurationRevision = baseRevision;

      services = {
        openssh.enable = true;
        tailscale.enable = true;
      };

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

      specialisation.next.configuration = {
        boot.kernelParams = [ "fleet-upgrade-push-test" ];
        system.configurationRevision = lib.mkForce nextRevision;
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
      ssh_opts = "-i /root/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"
      store = "ssh-ng://fleet-push@localhost?ssh-key=/root/.ssh/id_ed25519"
      nix_ssh = f"NIX_SSHOPTS='{ssh_opts}'"

      def publish(toplevel):
          plan = {
              "history": ["${nextRevision}", "${baseRevision}"],
              "hosts": {"machine": {"state": "planned", "reason": "none", "revision": "${nextRevision}", "toplevel": toplevel}},
          }
          machine.succeed(f"cat > /srv/plan.json <<'EOF'\n{json.dumps(plan)}\nEOF")

      def upgrade(expected_state, expected_reason):
          machine.succeed("systemctl start fleet-upgrade.service")
          line = machine.succeed(f"grep '^fleet_upgrade_state' {metrics}")
          assert f'state="{expected_state}",reason="{expected_reason}"' in line, line

      def generation():
          # Built elsewhere: the machine's store does not have it until it is pushed.
          machine.succeed(
              "git init -q -b deploy ${repo}",
              f"""cat > ${repo}/flake.nix <<'EOF'
      {{
        outputs = {{ self }}: {{
          toplevel = derivation {{
            name = "nixos-system-machine-generation";
            system = "${pkgs.stdenv.hostPlatform.system}";
            builder = "/bin/sh";
            args = [ "-c" "{coreutils}/ln -s {base}/specialisation/next $out; true" ];
          }};
        }};
      }}
      EOF""",
          )
          built = machine.succeed("nix build --no-link --print-out-paths path:${repo}#toplevel").strip()
          machine.succeed(f"nix copy --to file:///tmp/controller-cache {built}", f"nix store delete {built}")
          return built

      machine.wait_for_unit("plan-server.service")
      machine.wait_for_open_port(8000)
      machine.wait_for_unit("sshd.service")
      machine.succeed("install -d -m 0700 /root/.ssh && install -m 0600 ${pushKey}/id_ed25519 /root/.ssh/id_ed25519")

      toplevel = generation()

      with subtest("a planned generation that has not arrived is waited for"):
          machine.fail(f"nix-store --check-validity {toplevel}")
          publish(toplevel)
          upgrade("waiting", "push")
          machine.succeed(f'test "$(readlink -f /run/current-system)" = "$(readlink -f {base})"')

      with subtest("the controller key can only run the Nix daemon"):
          machine.execute(f"ssh {ssh_opts} fleet-push@localhost 'touch /tmp/escaped' < /dev/null")
          machine.fail("test -e /tmp/escaped")
          machine.succeed(f"{nix_ssh} nix store info --store '{store}' 2>&1 | grep -q 'Trusted: 1'")

      with subtest("a pushed generation is switched to without building"):
          machine.succeed(f"{nix_ssh} nix copy --no-check-sigs --from file:///tmp/controller-cache --to '{store}' {toplevel}")
          machine.succeed(f"nix-store --check-validity {toplevel}")
          upgrade("current", "none")
          machine.succeed(f'test "$(readlink -f /run/current-system)" = "$(readlink -f {base}/specialisation/next)"')
          upgrade("current", "none")
    '';
}
