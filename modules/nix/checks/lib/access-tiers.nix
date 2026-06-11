{
  pkgs,
  inputs,
  ...
}:
let
  inherit (pkgs) lib;

  testKeys = import ./fixtures/test-ed25519-keys.nix { inherit pkgs; };

  testCluster = {
    users = {
      admin-user = {
        id = "admin-user";
        kind = "human";
        cohort = "admin";
        allowed_hosts = [ "all" ];
        xrdp_access = false;
        expires = null;
        archived = false;
        archived_at = null;
        headscale_user = null;
        labels = { };
        keys = {
          ssh = [ testKeys.admin.publicKey ];
          age = [ ];
          u2f = [ ];
        };
        system_account = {
          username = "admin-user";
          uid = 1000;
          shell = "bash";
          groups = [ ];
          hashed_password_key = null;
        };
      };
      standard-user = {
        id = "standard-user";
        kind = "human";
        cohort = "staff";
        allowed_hosts = [ "all" ];
        xrdp_access = false;
        expires = null;
        archived = false;
        archived_at = null;
        headscale_user = null;
        labels = { };
        keys = {
          ssh = [ testKeys.admin.publicKey ];
          age = [ ];
          u2f = [ ];
        };
        system_account = {
          username = "standard-user";
          uid = 1001;
          shell = "bash";
          groups = [ ];
          hashed_password_key = null;
        };
      };
      viewer-user = {
        id = "viewer-user";
        kind = "human";
        cohort = "reviewer";
        allowed_hosts = [ "all" ];
        xrdp_access = false;
        expires = null;
        archived = false;
        archived_at = null;
        headscale_user = null;
        labels = { };
        keys = {
          ssh = [ testKeys.admin.publicKey ];
          age = [ ];
          u2f = [ ];
        };
        system_account = {
          username = "viewer-user";
          uid = 1002;
          shell = "bash";
          groups = [ ];
          hashed_password_key = null;
        };
      };
    };
    usersOnHost."tier-host" = [
      {
        user = "admin-user";
        tier = "admin";
        via_team = null;
        via_team_role = null;
        can_submit_to = [ ];
      }
      {
        user = "standard-user";
        tier = "standard";
        via_team = null;
        via_team_role = null;
        can_submit_to = [ ];
      }
      {
        user = "viewer-user";
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
      };
      standard = {
        ssh = {
          allowed = true;
        };
        sudo = null;
        extra_groups = [ ];
      };
      viewer = {
        ssh = {
          allowed = false;
        };
        sudo = null;
        extra_groups = [ ];
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
    assert "admin-user ALL=(ALL) NOPASSWD:ALL" in sudoers, (
        "FAIL: admin tier sudo grant missing from /etc/sudoers"
    )
    for forbidden in ("standard-user ALL=", "viewer-user ALL="):
        assert forbidden not in sudoers, (
            f"FAIL: unexpected sudoers line '{forbidden}...' in /etc/sudoers"
        )
    say("sudoers reflects tier policy")

    stage("static config: sshd_config DenyUsers")
    sshd_conf = tier_host.succeed("cat /etc/ssh/sshd_config")
    assert "DenyUsers viewer-user" in sshd_conf, (
        "FAIL: viewer tier denial missing from sshd_config"
    )
    assert "DenyUsers" in sshd_conf
    deny_line = [
        line for line in sshd_conf.splitlines() if line.startswith("DenyUsers")
    ]
    assert len(deny_line) == 1, f"FAIL: expected exactly one DenyUsers line, got {deny_line!r}"
    assert "admin-user" not in deny_line[0], "FAIL: admin-user wrongly denied"
    assert "standard-user" not in deny_line[0], "FAIL: standard-user wrongly denied"
    say(f"sshd_config DenyUsers line: {deny_line[0]!r}")

    stage("account existence (denial is at SSH layer, not account layer)")
    for u in ("admin-user", "standard-user", "viewer-user"):
        out = tier_host.succeed(f"getent passwd {u}").strip()
        say(f"getent {u}: {out}")
    assert "1002" in tier_host.succeed("getent passwd viewer-user"), (
        "FAIL: viewer-user account missing uid 1002"
    )

    stage("install test private keys")
    tier_host.succeed(
        "install -m 0600 ${testKeys.admin.privateKey} /tmp/admin-user-id",
        "install -m 0600 ${testKeys.admin.privateKey} /tmp/standard-user-id",
        "install -m 0600 ${testKeys.admin.privateKey} /tmp/viewer-user-id",
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

    stage("SSH: admin tier gets in")
    ssh_try("admin-user-id", "admin-user", True, "admin-user@localhost (admin tier)")

    stage("SSH: standard tier gets in")
    ssh_try("standard-user-id", "standard-user", True, "standard-user@localhost (standard tier)")

    stage("SSH: viewer tier is REJECTED")
    ssh_try("viewer-user-id", "viewer-user", False, "viewer-user@localhost (viewer tier, DenyUsers)")

    stage("sudo: admin-user runs sudo -n true (NOPASSWD admin)")
    rc, out = tier_host.execute("sudo -u admin-user sudo -n true", timeout=15)
    assert rc == 0, f"FAIL: admin-user cannot sudo NOPASSWD; rc={rc}, out={out!r}"
    say("admin-user sudo NOPASSWD works")

    stage("sudo: standard-user CANNOT sudo (standard tier, no grant)")
    rc, out = tier_host.execute("sudo -u standard-user sudo -n true", timeout=15)
    assert rc != 0, f"FAIL: standard-user should not be able to sudo; rc={rc}, out={out!r}"
    say("standard-user sudo correctly denied")

    stage("sudo: viewer-user CANNOT sudo (viewer tier, no grant)")
    rc, out = tier_host.execute("sudo -u viewer-user sudo -n true", timeout=15)
    assert rc != 0, f"FAIL: viewer-user should not be able to sudo; rc={rc}, out={out!r}"
    say("viewer-user sudo correctly denied")

    stage(f"DONE in {time.time() - t0:.1f}s")
    print("ACCESS-TIER WIRING VERIFICATIONS PASSED")
  '';
}
