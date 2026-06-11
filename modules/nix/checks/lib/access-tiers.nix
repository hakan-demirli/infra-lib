{
  pkgs,
  inputs,
  ...
}:
let
  inherit (pkgs) lib;

  mkKeypair =
    name:
    pkgs.runCommand "key-${name}"
      {
        nativeBuildInputs = [ pkgs.openssh ];
      }
      ''
        mkdir -p $out
        ssh-keygen -t ed25519 -N "" -C "${name}@tier-test" -f $out/id_ed25519
      '';

  emreKp = mkKeypair "emre";
  sahandKp = mkKeypair "sahand";
  vinceKp = mkKeypair "vince";

  readPub = kp: lib.removeSuffix "\n" (builtins.readFile "${kp}/id_ed25519.pub");

  testCluster = {
    users = {
      user-0 = {
        id = "user-0";
        kind = "human";
        cohort = "admin";
        is_root_anywhere = true;
        allowed_hosts = [ "all" ];
        xrdp_access = false;
        expires = null;
        archived = false;
        archived_at = null;
        headscale_user = null;
        labels = { };
        keys = {
          ssh = [ (readPub emreKp) ];
          age = [ ];
          u2f = [ ];
        };
        system_account = {
          username = "emre";
          uid = 1000;
          shell = "bash";
          groups = [ ];
          home = "/home/emre";
          hashed_password_key = null;
        };
      };
      user-1 = {
        id = "user-1";
        kind = "human";
        cohort = "staff";
        is_root_anywhere = false;
        allowed_hosts = [ "all" ];
        xrdp_access = false;
        expires = null;
        archived = false;
        archived_at = null;
        headscale_user = null;
        labels = { };
        keys = {
          ssh = [ (readPub sahandKp) ];
          age = [ ];
          u2f = [ ];
        };
        system_account = {
          username = "sahand";
          uid = 1001;
          shell = "bash";
          groups = [ ];
          home = "/home/sahand";
          hashed_password_key = null;
        };
      };
      user-2 = {
        id = "user-2";
        kind = "human";
        cohort = "reviewer";
        is_root_anywhere = false;
        allowed_hosts = [ "all" ];
        xrdp_access = false;
        expires = null;
        archived = false;
        archived_at = null;
        headscale_user = null;
        labels = { };
        keys = {
          ssh = [ (readPub vinceKp) ];
          age = [ ];
          u2f = [ ];
        };
        system_account = {
          username = "vince";
          uid = 1002;
          shell = "bash";
          groups = [ ];
          home = "/home/vince";
          hashed_password_key = null;
        };
      };
    };
    usersOnHost."tier-host" = [
      {
        user = "user-0";
        tier = "admin";
        via_team = null;
        via_team_role = null;
        can_submit_to = [ ];
      }
      {
        user = "user-1";
        tier = "standard";
        via_team = null;
        via_team_role = null;
        can_submit_to = [ ];
      }
      {
        user = "user-2";
        tier = "viewer";
        via_team = null;
        via_team_role = null;
        can_submit_to = [ ];
      }
    ];
    accessTiers = {
      admin = {
        ssh = {
          allowed = true;
        };
        sudo = "NOPASSWD:ALL";
        extra_groups = [ "wheel" ];
        slurm_qos = null;
      };
      standard = {
        ssh = {
          allowed = true;
        };
        sudo = null;
        extra_groups = [ ];
        slurm_qos = null;
      };
      viewer = {
        ssh = {
          allowed = false;
        };
        sudo = null;
        extra_groups = [ ];
        slurm_qos = null;
      };
    };
  };

  testHost = {
    id = "tier-host";
    ssh_trust = { };
    boot = {
      kernel_package = null;
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "access-tiers";

  nodes.tier_host =
    { ... }:
    {
      imports = [
        inputs.sops-nix.nixosModules.sops
        ../../../common/cluster-users.nix
        ../../../common/sshd.nix
      ];

      _module.args = {
        host = testHost;
        cluster = testCluster;
      };

      users.withSops = false;
      services.openssh.enable = lib.mkForce true;
      networking.firewall.enable = lib.mkForce false;

      networking.networkmanager.enable = lib.mkForce false;

      virtualisation = {
        memorySize = 1024;
        cores = 2;
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
    tier_host.wait_for_unit("multi-user.target", timeout=120)
    tier_host.wait_for_unit("sshd.service", timeout=60)
    tier_host.wait_for_open_port(22, timeout=60)
    say("VM up; sshd listening")

    stage("static config: sudoers")
    sudoers = tier_host.succeed("cat /etc/sudoers")
    print(sudoers)
    assert "emre ALL=(ALL) NOPASSWD:ALL" in sudoers, (
        "FAIL: admin tier sudo grant missing from /etc/sudoers"
    )
    for forbidden in ("sahand ALL=", "vince ALL="):
        assert forbidden not in sudoers, (
            f"FAIL: unexpected sudoers line '{forbidden}...' in /etc/sudoers"
        )
    say("sudoers reflects tier policy")

    stage("static config: sshd_config DenyUsers")
    sshd_conf = tier_host.succeed("cat /etc/ssh/sshd_config")
    assert "DenyUsers vince" in sshd_conf, (
        "FAIL: viewer tier denial missing from sshd_config"
    )
    assert "DenyUsers" in sshd_conf
    deny_line = [
        line for line in sshd_conf.splitlines() if line.startswith("DenyUsers")
    ]
    assert len(deny_line) == 1, f"FAIL: expected exactly one DenyUsers line, got {deny_line!r}"
    assert "emre" not in deny_line[0], "FAIL: emre wrongly denied"
    assert "sahand" not in deny_line[0], "FAIL: sahand wrongly denied"
    say(f"sshd_config DenyUsers line: {deny_line[0]!r}")

    stage("account existence (denial is at SSH layer, not account layer)")
    for u in ("emre", "sahand", "vince"):
        out = tier_host.succeed(f"getent passwd {u}").strip()
        say(f"getent {u}: {out}")
    assert "1002" in tier_host.succeed("getent passwd vince"), (
        "FAIL: vince account missing uid 1002"
    )

    stage("install test private keys")
    tier_host.succeed(
        "install -m 0600 ${emreKp}/id_ed25519 /tmp/emre_id",
        "install -m 0600 ${sahandKp}/id_ed25519 /tmp/sahand_id",
        "install -m 0600 ${vinceKp}/id_ed25519 /tmp/vince_id",
    )

    ssh_opts = (
        "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-o BatchMode=yes -o ConnectTimeout=10"
    )

    def ssh_try(key, user, expect_ok, msg):
        cmd = f"ssh {ssh_opts} -i /tmp/{key} {user}@localhost true"
        rc, out = tier_host.execute(cmd, timeout=20)
        ok = (rc == 0) == expect_ok
        if not ok:
            say(f"!!! FAIL: {msg}; rc={rc}; output:")
            print(out)
            raise Exception(f"{msg} (rc={rc}, expected_ok={expect_ok})")
        say(f"OK {msg} (rc={rc})")

    stage("SSH: admin tier (emre) gets in")
    ssh_try("emre_id", "emre", True, "emre@localhost (admin tier)")

    stage("SSH: standard tier (sahand) gets in")
    ssh_try("sahand_id", "sahand", True, "sahand@localhost (standard tier)")

    stage("SSH: viewer tier (vince) is REJECTED")
    ssh_try("vince_id", "vince", False, "vince@localhost (viewer tier, DenyUsers)")

    stage("sudo: emre runs sudo -n true (NOPASSWD admin)")
    rc, out = tier_host.execute("sudo -u emre sudo -n true", timeout=15)
    assert rc == 0, f"FAIL: emre cannot sudo NOPASSWD; rc={rc}, out={out!r}"
    say("emre sudo NOPASSWD works")

    stage("sudo: sahand CANNOT sudo (standard tier, no grant)")
    rc, out = tier_host.execute("sudo -u sahand sudo -n true", timeout=15)
    assert rc != 0, f"FAIL: sahand should not be able to sudo; rc={rc}, out={out!r}"
    say("sahand sudo correctly denied")

    stage("sudo: vince CANNOT sudo (viewer tier, no grant)")
    rc, out = tier_host.execute("sudo -u vince sudo -n true", timeout=15)
    assert rc != 0, f"FAIL: vince should not be able to sudo; rc={rc}, out={out!r}"
    say("vince sudo correctly denied")

    stage(f"DONE in {time.time() - t0:.1f}s")
    print("ACCESS-TIER WIRING VERIFICATIONS PASSED")
  '';
}
