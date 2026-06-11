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
        ssh-keygen -t ed25519 -N "" -C "${name}@test" -f $out/id_ed25519
      '';

  emreKp = mkKeypair "emre";
  sahandKp = mkKeypair "sahand";

  readPub = kp: builtins.readFile "${kp}/id_ed25519.pub";

  emrePub = readPub emreKp;
  sahandPub = readPub sahandKp;

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
          ssh = [ (lib.removeSuffix "\n" emrePub) ];
          age = [ ];
          u2f = [ ];
        };
        system_account = {
          username = "emre";
          uid = 1000;
          shell = "bash";
          groups = [ "wheel" ];
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
          ssh = [ (lib.removeSuffix "\n" sahandPub) ];
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
    };
    usersOnHost."dev-fpga-0" = [
      {
        user = "user-0";
        tier = "admin";
        via_team = "team-dev-box";
        via_team_role = "admin";
        can_submit_to = [ ];
      }
      {
        user = "user-1";
        tier = "standard";
        via_team = "team-dev-box";
        via_team_role = "member";
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
        slurm_qos = { };
      };
      standard = {
        ssh = {
          allowed = true;
        };
        sudo = null;
        extra_groups = [ ];
        slurm_qos = { };
      };
    };
  };

  testHost = {
    id = "dev-fpga-0";
    ssh_trust = {
      emre = [
        "user-0"
        "user-1"
      ];
      sahand = [ "user-1" ];
      root = [
        "user-0"
        "user-1"
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
        "install -m 0600 ${emreKp}/id_ed25519 /tmp/emre_id",
        "install -m 0600 ${sahandKp}/id_ed25519 /tmp/sahand_id",
    )
    say("private keys staged in /tmp")

    stage("verify users exist with the expected pubkeys")
    say("emre authorized_keys:")
    print(dev_fpga.succeed("cat /etc/ssh/authorized_keys.d/emre || cat /home/emre/.ssh/authorized_keys || true"))
    say("sahand authorized_keys:")
    print(dev_fpga.succeed("cat /etc/ssh/authorized_keys.d/sahand || cat /home/sahand/.ssh/authorized_keys || true"))
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

    stage("INVARIANT 1: emre key reaches emre@host (self)")
    ssh_try("emre_id", "emre", expect_ok=True)

    stage("INVARIANT 2: sahand key reaches emre@host (ssh_trust delegation)")
    ssh_try("sahand_id", "emre", expect_ok=True)

    stage("INVARIANT 3: sahand key reaches sahand@host (self)")
    ssh_try("sahand_id", "sahand", expect_ok=True)

    stage("INVARIANT 4: emre key BLOCKED from sahand@host (asymmetry)")
    ssh_try("emre_id", "sahand", expect_ok=False)

    stage("INVARIANT 5: emre key reaches root@host (is_root_anywhere admin)")
    ssh_try("emre_id", "root", expect_ok=True)

    stage("INVARIANT 6: sahand key reaches root@host (host-local root via ssh_trust)")
    ssh_try("sahand_id", "root", expect_ok=True)

    stage(f"DONE in {time.time() - t0:.1f}s")
    print("DEV-FPGA SCHEMA VERIFICATIONS PASSED")
  '';
}
