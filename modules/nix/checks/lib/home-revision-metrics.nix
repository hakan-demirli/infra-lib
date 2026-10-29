{
  pkgs,
  ...
}:
let
  inherit (pkgs) lib;
  metricsFile = "/var/lib/prometheus-node-exporter-textfiles/fleet-revisions.prom";
  revision = "0123456789abcdef0123456789abcdef01234567";
  generation =
    content:
    pkgs.runCommand "home-manager-generation" { } (
      ''
        mkdir "$out"
      ''
      + lib.optionalString (content != null) ''
        printf '%s\n' ${lib.escapeShellArg content} > "$out/fleet-revision"
      ''
    );
  fleet = generation revision;
  dirty = generation "${revision}-dirty";
  legacy = generation null;
  linked = pkgs.runCommand "home-manager-generation" { } ''
    mkdir "$out"
    ln -s ${pkgs.writeText "fleet-revision" revision} "$out/fleet-revision"
  '';
in
pkgs.testers.runNixOSTest {
  name = "home-revision-metrics";

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
        };
        bob = {
          isNormalUser = true;
          uid = 1001;
        };
      };

      system.extraDependencies = [
        fleet
        dirty
        legacy
        linked
      ];
      virtualisation.memorySize = 1024;
    };

  testScript = ''
    def collect():
        machine.succeed(
            "systemctl reset-failed fleet-revision-metrics.service",
            "systemctl start fleet-revision-metrics.service",
        )
        return [
            line
            for line in machine.succeed("cat ${metricsFile}").splitlines()
            if line.startswith("fleet_home_manager_generation_info{")
        ]

    def activate(user, target):
        gcroots = f"/home/{user}/.local/state/home-manager/gcroots"
        machine.succeed(f"runuser -u {user} -- mkdir -p {gcroots}")
        machine.succeed(f"runuser -u {user} -- ln -sfnT {target} {gcroots}/current-home")

    def closure(path):
        return path.rsplit("/", 1)[1]

    def series(revision, kind, closure):
        return (
            f'fleet_home_manager_generation_info{{host="machine",user="alice",'
            f'revision="{revision}",revision_kind="{kind}",closure="{closure}"}} 1'
        )

    machine.wait_for_unit("multi-user.target")

    with subtest("an owner without an active home exports no series"):
        assert collect() == [], collect()

    with subtest("only the owner home is exported, with its source revision"):
        activate("bob", "${fleet}")
        activate("alice", "${fleet}")
        exported = collect()
        assert exported == [series("${revision}", "git", closure("${fleet}"))], exported

    with subtest("a dirty tree build is local"):
        activate("alice", "${dirty}")
        exported = collect()
        assert exported == [series("${revision}-dirty", "local", closure("${dirty}"))], exported

    with subtest("a generation without a revision is unknown"):
        activate("alice", "${legacy}")
        exported = collect()
        assert exported == [series("unknown", "unknown", closure("${legacy}"))], exported

    with subtest("a linked revision file is not followed"):
        activate("alice", "${linked}")
        exported = collect()
        assert exported == [series("unknown", "unknown", closure("${linked}"))], exported

    with subtest("a mutable or dangling target is unknown"):
        fake = "/home/alice/fake-home-manager-generation"
        machine.succeed(f"runuser -u alice -- mkdir -p {fake}")
        machine.succeed(f"runuser -u alice -- sh -c 'printf %s ${revision} > {fake}/fleet-revision'")
        activate("alice", fake)
        exported = collect()
        assert exported == [series("unknown", "unknown", "unknown")], exported
        activate("alice", "/nix/store/00000000000000000000000000000000-home-manager-generation")
        exported = collect()
        assert exported == [series("unknown", "unknown", "unknown")], exported

    with subtest("node exporter serves the owner home"):
        activate("alice", "${fleet}")
        collect()
        machine.wait_for_unit("prometheus-node-exporter.service")
        machine.wait_for_open_port(9100)
        served = machine.succeed("curl -fsS http://127.0.0.1:9100/metrics")
        expected = (
            f'fleet_home_manager_generation_info{{closure="{closure("${fleet}")}",host="machine",'
            f'revision="${revision}",revision_kind="git",user="alice"}} 1'
        )
        assert expected in served.splitlines(), served
  '';
}
