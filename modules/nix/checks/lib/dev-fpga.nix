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
          username = "admin-user";
          uid = 1000;
          shell = "bash";
          groups = [ "wheel" ];
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
          ssh = [ testKeys.standard.publicKey ];
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
    };
    usersOnHost."dev-fpga-0" = [
      {
        user = "admin-user";
        unix_tier = "admin";
        via_team = "team-dev-box";
        via_team_role = "admin";
        can_submit_to = [ ];
      }
      {
        user = "standard-user";
        unix_tier = "standard";
        via_team = "team-dev-box";
        via_team_role = "member";
        can_submit_to = [ ];
      }
    ];
    unixAccessTiers = {
      admin = {
        ssh = {
          allowed = true;
        };
        sudo.extra_rule = "NOPASSWD:ALL";
        groups = [ "wheel" ];
        root_ssh = true;
      };
      standard = {
        ssh = {
          allowed = true;
        };
        sudo.extra_rule = null;
        groups = [ ];
        root_ssh = false;
      };
    };
  };

  testHost = {
    id = "dev-fpga-0";
    ssh_trust = {
      admin-user = [
        "admin-user"
        "standard-user"
      ];
      standard-user = [ "standard-user" ];
      root = [
        "admin-user"
        "standard-user"
      ];
    };
    boot = {
      kernel_package = "linuxPackages_5_15";
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "dev-fpga";

  nodes.dev_fpga =
    { ... }:
    {
      imports = [
        inputs.sops-nix.nixosModules.sops
        ../../../common/cluster-users.nix
        ../../../common/sshd.nix
        ../../../system/server-base.nix
      ];

      _module.args = {
        host = testHost;
        cluster = testCluster;
      };

      users.withSops = false;
      services.openssh.enable = lib.mkForce true;
      networking.firewall.enable = lib.mkForce false;

      networking.networkmanager.enable = lib.mkForce false;

      system.server.enable = lib.mkForce true;

      virtualisation = {
        memorySize = 1280;
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
    dev_fpga.wait_for_unit("multi-user.target", timeout=120)
    dev_fpga.wait_for_unit("sshd.service", timeout=60)
    dev_fpga.wait_for_open_port(22, timeout=60)
    say("dev-fpga up; sshd listening")

    stage("kernel pin")
    uname_r = dev_fpga.succeed("uname -r").strip()
    say(f"uname -r = {uname_r}")
    assert uname_r.startswith("5.15."), (
        f"FAIL: kernel pinned to linuxPackages_5_15 but uname -r = {uname_r!r}"
    )

    stage("install test private keys")
    dev_fpga.succeed(
        "install -m 0600 ${testKeys.admin.privateKey} /tmp/admin-user-id",
        "install -m 0600 ${testKeys.standard.privateKey} /tmp/standard-user-id",
    )
    say("private keys staged in /tmp")

    stage("verify users exist with the expected pubkeys")
    say("admin-user authorized_keys:")
    print(dev_fpga.succeed("cat /etc/ssh/authorized_keys.d/admin-user || cat /home/admin-user/.ssh/authorized_keys || true"))
    say("standard-user authorized_keys:")
    print(dev_fpga.succeed("cat /etc/ssh/authorized_keys.d/standard-user || cat /home/standard-user/.ssh/authorized_keys || true"))
    say("root authorized_keys:")
    print(dev_fpga.succeed("cat /etc/ssh/authorized_keys.d/root || cat /root/.ssh/authorized_keys || true"))

    ssh_opts = (
        "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-o BatchMode=yes -o ConnectTimeout=10"
    )

    def ssh_try(key, target, expect_ok):
        cmd = f"ssh {ssh_opts} -i /tmp/{key} {target}@localhost true"
        rc, out = dev_fpga.execute(cmd, timeout=20)
        label = "EXPECTED-OK" if expect_ok else "EXPECTED-FAIL"
        ok = (rc == 0) == expect_ok
        if not ok:
            say(f"!!! ({label}) ssh -i /tmp/{key} {target}@localhost -> rc={rc}; "
                f"diagnostic output below")
            print(out)
            raise Exception(f"ssh matrix violation: key={key} target={target} rc={rc} expect_ok={expect_ok}")
        say(f"OK ({label}) ssh -i /tmp/{key} {target}@localhost (rc={rc})")

    stage("INVARIANT 1: admin key reaches admin-user@host (self)")
    ssh_try("admin-user-id", "admin-user", expect_ok=True)

    stage("INVARIANT 2: standard key reaches admin-user@host (ssh_trust delegation)")
    ssh_try("standard-user-id", "admin-user", expect_ok=True)

    stage("INVARIANT 3: standard key reaches standard-user@host (self)")
    ssh_try("standard-user-id", "standard-user", expect_ok=True)

    stage("INVARIANT 4: admin key BLOCKED from standard-user@host (asymmetry)")
    ssh_try("admin-user-id", "standard-user", expect_ok=False)

    stage("INVARIANT 5: admin key reaches root@host (admin Unix tier)")
    ssh_try("admin-user-id", "root", expect_ok=True)

    stage("INVARIANT 6: standard key reaches root@host (host-local root via ssh_trust)")
    ssh_try("standard-user-id", "root", expect_ok=True)

    stage(f"DONE in {time.time() - t0:.1f}s")
    print("DEV-FPGA SCHEMA VERIFICATIONS PASSED")
  '';
}
