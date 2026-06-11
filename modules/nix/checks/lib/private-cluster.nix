{
  pkgs,
  ...
}:
let
  testlib = import ./lib.nix { inherit pkgs; };

  aclFile = pkgs.writeText "private-cluster.hujson" (
    builtins.toJSON {
      groups = {
        "group:admin" = [ "owner@" ];
      };
      tagOwners = {
        "tag:cluster-priv" = [ "group:admin" ];
        "tag:cluster-priv-controller" = [ "group:admin" ];
        "tag:cluster-priv-compute" = [ "group:admin" ];
      };
      acls = [
        {
          action = "accept";
          src = [ "group:admin" ];
          dst = [
            "tag:cluster-priv:*"
            "tag:cluster-priv-controller:*"
            "tag:cluster-priv-compute:*"
          ];
        }
        {
          action = "accept";
          src = [ "tag:cluster-priv-compute" ];
          dst = [ "tag:cluster-priv-compute:*" ];
        }
        {
          action = "accept";
          src = [ "tag:cluster-priv-controller" ];
          dst = [ "tag:cluster-priv-compute:*" ];
        }
        {
          action = "accept";
          src = [ "tag:cluster-priv-compute" ];
          dst = [ "tag:cluster-priv-controller:*" ];
        }
      ];
    }
  );

  clusterHosts = ''
    192.168.1.1 headscale
    192.168.1.2 compute1
    192.168.1.3 compute2
    192.168.1.4 master
    192.168.1.5 owner-laptop
    192.168.1.6 stranger-laptop
  '';

  clusterNodes = [
    {
      hostName = "master";
      cores = 2;
      ramMb = 2048;
    }
    {
      hostName = "compute1";
      cores = 2;
      ramMb = 1536;
    }
    {
      hostName = "compute2";
      cores = 2;
      ramMb = 1536;
    }
  ];
in
pkgs.testers.runNixOSTest {
  name = "private-cluster";

  nodes = {
    a_headscale = testlib.mkHeadscaleNode { inherit aclFile; };

    master =
      { ... }:
      {
        imports = [
          (testlib.mkSlurmMaster {
            hostName = "master";
            inherit clusterNodes;
          })
          (testlib.mkTailscaleNode {
            extraUpFlags = [ "--advertise-tags=tag:cluster-priv-controller" ];
          })
        ];
        networking.extraHosts = clusterHosts;
        users.users.owner = {
          isNormalUser = true;
          uid = 1000;
          extraGroups = [ "wheel" ];
        };
      };

    compute1 =
      { ... }:
      {
        imports = [
          (testlib.mkSlurmCompute {
            hostName = "compute1";
            masterHostname = "master";
            inherit clusterNodes;
            adopt = true;
          })
          (testlib.mkTailscaleNode {
            extraUpFlags = [ "--advertise-tags=tag:cluster-priv-compute" ];
          })
        ];
        networking.extraHosts = clusterHosts;
        users.users.owner = {
          isNormalUser = true;
          uid = 1000;
          extraGroups = [ "wheel" ];
        };
      };

    compute2 =
      { ... }:
      {
        imports = [
          (testlib.mkSlurmCompute {
            hostName = "compute2";
            masterHostname = "master";
            inherit clusterNodes;
            adopt = true;
          })
          (testlib.mkTailscaleNode {
            extraUpFlags = [ "--advertise-tags=tag:cluster-priv-compute" ];
          })
        ];
        networking.extraHosts = clusterHosts;
        users.users.owner = {
          isNormalUser = true;
          uid = 1000;
          extraGroups = [ "wheel" ];
        };
      };

    owner_laptop =
      { pkgs, ... }:
      {
        imports = [ (testlib.mkTailscaleNode { }) ];
        networking.extraHosts = clusterHosts;
        environment.systemPackages = [ pkgs.openssh ];
        users.users.owner = {
          isNormalUser = true;
          uid = 1000;
        };
      };

    stranger_laptop =
      { ... }:
      {
        imports = [ (testlib.mkTailscaleNode { }) ];
        networking.extraHosts = clusterHosts;
        users.users.stranger = {
          isNormalUser = true;
          uid = 1100;
        };
      };
  };

  testScript = ''
    import time, json

    t0 = time.time()
    def stage(msg):
        print(f"\n========== [t+{time.time() - t0:6.1f}s] {msg} ==========")
    def say(msg):
        print(f"[t+{time.time() - t0:6.1f}s] {msg}")

    stage("start_all: booting 6 VMs")
    start_all()

    headscale = a_headscale  # readability alias

    stage("wait for tailscaled on every tailscale node")
    for n, name in [
        (headscale, "headscale"),
        (master, "master"),
        (compute1, "compute1"),
        (compute2, "compute2"),
        (owner_laptop, "owner_laptop"),
        (stranger_laptop, "stranger_laptop"),
    ]:
        n.wait_for_unit("network.target", timeout=120)
        say(f"network.target up on {name}")
    for n, name in [
        (master, "master"),
        (compute1, "compute1"),
        (compute2, "compute2"),
        (owner_laptop, "owner_laptop"),
        (stranger_laptop, "stranger_laptop"),
    ]:
        n.wait_for_unit("tailscaled.service", timeout=120)
        say(f"tailscaled up on {name}")

    stage("boot headscale + nginx + DERP")
    headscale.wait_for_unit("headscale.service", timeout=120)
    headscale.wait_for_unit("nginx.service", timeout=60)
    headscale.wait_for_open_port(8080, timeout=60)
    headscale.wait_for_open_port(443, timeout=60)
    say("headscale serving on :443")

    stage("headscale users + preauth keys")
    headscale.succeed("headscale users create owner")
    headscale.succeed("headscale users create stranger")

    def user_id(name):
        out = headscale.succeed("headscale users list --output json")
        for u in json.loads(out):
            if u.get("name") == name:
                return u["id"]
        raise Exception(f"user {name!r} not found in {out}")

    owner_id = user_id("owner")
    stranger_id = user_id("stranger")

    ctrl_key = headscale.succeed(
        "headscale preauthkeys create --reusable --expiration 24h "
        "--tags tag:cluster-priv-controller"
    ).strip()
    say("got controller preauth key")
    compute_key = headscale.succeed(
        "headscale preauthkeys create --reusable --expiration 24h "
        "--tags tag:cluster-priv-compute"
    ).strip()
    say("got compute preauth key")
    owner_key = headscale.succeed(
        f"headscale preauthkeys create --user {owner_id} --reusable --expiration 24h"
    ).strip()
    say("got owner preauth key")
    stranger_key = headscale.succeed(
        f"headscale preauthkeys create --user {stranger_id} --reusable --expiration 24h"
    ).strip()
    say("got stranger preauth key")

    stage("join tailnet")
    def join(node, hostname, key):
        say(f"joining {hostname}")
        node.succeed(
            f"tailscale up --authkey={key} --hostname={hostname} "
            f"--login-server=https://headscale --timeout=60s"
        )
        node.wait_until_succeeds(
            f"tailscale status | grep -E '\\b{hostname}\\b' >&2",
            timeout=60,
        )
        headscale.wait_until_succeeds(
            f"headscale nodes list | grep -F {hostname}",
            timeout=60,
        )
        say(f"{hostname} joined and registered")

    join(master, "master", ctrl_key)
    join(compute1, "compute1", compute_key)
    join(compute2, "compute2", compute_key)
    join(owner_laptop, "owner-laptop", owner_key)
    join(stranger_laptop, "stranger-laptop", stranger_key)

    stage("resolve tailnet IPs")
    def ts_ip(node, name):
        ip = node.wait_until_succeeds("tailscale ip -4 | head -n1", timeout=60).strip()
        say(f"{name} = {ip}")
        return ip

    master_ts = ts_ip(master, "master")
    compute1_ts = ts_ip(compute1, "compute1")
    compute2_ts = ts_ip(compute2, "compute2")
    owner_ts = ts_ip(owner_laptop, "owner_laptop")
    stranger_ts = ts_ip(stranger_laptop, "stranger_laptop")

    stage("SLURM bring-up (LAN-based for deterministic IPs)")
    for n, name in [(master, "master"), (compute1, "compute1"), (compute2, "compute2")]:
        n.wait_for_unit("munged.service", timeout=120)
        say(f"munged up on {name}")
    master.wait_for_unit("slurmctld.service", timeout=120)
    say("slurmctld up on master")
    for n, name in [(compute1, "compute1"), (compute2, "compute2")]:
        n.wait_for_unit("slurmd.service", timeout=120)
        say(f"slurmd up on {name}")

    stage("compute nodes reach IDLE")
    master.succeed(
        "for i in $(seq 1 60); do "
        "  idle=$(sinfo -h -N -o '%T' | grep -c idle || true); "
        "  echo \"attempt $i: $idle idle nodes\"; "
        "  if [ \"$idle\" -ge 2 ]; then sinfo -N; exit 0; fi; "
        "  scontrol update nodename=compute1 state=resume 2>/dev/null || true; "
        "  scontrol update nodename=compute2 state=resume 2>/dev/null || true; "
        "  sleep 2; "
        "done; echo TIMEOUT; sinfo -N; scontrol show nodes; exit 1"
    )
    say("both compute nodes IDLE")

    stage("INVARIANT 1: srun spans real partition")
    with subtest("srun -N2 -p compute hostname returns both compute nodes"):
        out = master.succeed("srun -N2 -p compute hostname")
        say(f"srun output: {out!r}")
        assert "compute1" in out and "compute2" in out, f"srun didn't span: {out!r}"

    stage("provision owner SSH key + push to every node")
    owner_laptop.succeed(
        "su - owner -c 'ssh-keygen -t ed25519 -N \"\" -f /home/owner/.ssh/id_ed25519'"
    )
    owner_pub = owner_laptop.succeed("cat /home/owner/.ssh/id_ed25519.pub").strip()
    say("generated owner key")
    for n, name in [(master, "master"), (compute1, "compute1"), (compute2, "compute2")]:
        n.succeed("install -d -o owner -g users -m 0700 /home/owner/.ssh")
        n.succeed(
            f"echo '{owner_pub}' > /home/owner/.ssh/authorized_keys && "
            "chown owner: /home/owner/.ssh/authorized_keys && "
            "chmod 600 /home/owner/.ssh/authorized_keys"
        )
        say(f"pushed owner authorized_keys to {name}")

    stage("diagnostics: PAM stack + auth state on compute1")
    say("compute1 /etc/pam.d/sshd:")
    print(compute1.succeed("cat /etc/pam.d/sshd"))
    say("compute1 groups for owner:")
    print(compute1.succeed("id owner; groups owner"))
    say("compute1 sshd config (effective):")
    print(compute1.succeed("sshd -T 2>&1 | grep -E 'usepam|pubkey|password|permitroot' || true"))

    stage("INVARIANT 2: owner SSHes directly to every node over tailnet")
    ssh_opts = (
        "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-o BatchMode=yes -o ConnectTimeout=10"
    )
    for ip, name in [(master_ts, "master"), (compute1_ts, "compute1"), (compute2_ts, "compute2")]:
        owner_laptop.wait_until_succeeds(f"ping -c 2 -W 4 {ip}", timeout=60)
        say(f"owner pings {name} ({ip})")
        with subtest(f"owner SSHes to {name}"):
            rc, out = owner_laptop.execute(
                f"su - owner -c 'ssh -vvv {ssh_opts} -i /home/owner/.ssh/id_ed25519 owner@{ip} true 2>&1'",
                timeout=30,
            )
            if rc != 0:
                say(f"!!! SSH failed rc={rc}; last 80 lines of ssh -vvv:")
                print("\n".join(out.splitlines()[-80:]))
                target = master if name == "master" else (compute1 if name == "compute1" else compute2)
                say(f"remote sshd journal on {name}:")
                print(target.succeed(
                    "journalctl -u sshd --no-pager -n 50 || true; "
                    "journalctl -t sshd-session --no-pager -n 50 || true"
                ))
                raise Exception(f"owner SSH to {name} failed")
            say(f"OK owner SSHed to {name}")

    stage("INVARIANT 3: owner submits sbatch from master")
    with subtest("owner sbatch on master"):
        master.succeed(
            "su - owner -c \"sbatch -p compute -N1 -t 00:01:00 "
            "--wrap='hostname > /tmp/job.out' -o /tmp/sbatch.log\""
        )
        master.succeed(
            "for i in $(seq 1 60); do "
            "  if ! squeue -h | grep -q .; then exit 0; fi; sleep 2; "
            "done; squeue; exit 1"
        )
        say("sbatch job drained from queue")

    stage("INVARIANT 4: stranger blocked from cluster on the tailnet")
    with subtest("stranger cannot ping master"):
        stranger_laptop.fail(f"ping -c 2 -W 2 {master_ts}")
        say("OK stranger blocked from master")
    with subtest("stranger cannot ping compute1"):
        stranger_laptop.fail(f"ping -c 2 -W 2 {compute1_ts}")
        say("OK stranger blocked from compute1")
    with subtest("stranger cannot SSH master"):
        stranger_laptop.fail(f"ssh {ssh_opts} stranger@{master_ts} true")
        say("OK stranger SSH rejected at master")

    stage(f"DONE in {time.time() - t0:.1f}s")
    print("PRIVATE CLUSTER VERIFICATIONS PASSED")
  '';
}
