{
  pkgs,
  ...
}:
let
  testlib = import ./lib.nix { inherit pkgs; };

  clusterHosts = ''
    192.168.1.1 compute1
    192.168.1.2 compute2
    192.168.1.3 compute3
    192.168.1.4 compute4
    192.168.1.5 controller
    192.168.1.6 login
  '';

  clusterNodes = [
    {
      hostName = "controller";
      sockets = 1;
      coresPerSocket = 2;
      threadsPerCore = 1;
      ramMb = 2048;
    }
    {
      hostName = "compute1";
      sockets = 1;
      coresPerSocket = 2;
      threadsPerCore = 1;
      ramMb = 1536;
    }
    {
      hostName = "compute2";
      sockets = 1;
      coresPerSocket = 2;
      threadsPerCore = 1;
      ramMb = 1536;
    }
    {
      hostName = "compute3";
      sockets = 1;
      coresPerSocket = 2;
      threadsPerCore = 1;
      ramMb = 1536;
    }
    {
      hostName = "compute4";
      sockets = 1;
      coresPerSocket = 2;
      threadsPerCore = 1;
      ramMb = 1536;
    }
  ];

  researchers = [
    {
      name = "res1";
      uid = 1001;
    }
    {
      name = "res2";
      uid = 1002;
    }
    {
      name = "res3";
      uid = 1003;
    }
    {
      name = "res4";
      uid = 1004;
    }
  ];

  mkResearchers = builtins.listToAttrs (
    map (r: {
      inherit (r) name;
      value = {
        isNormalUser = true;
        inherit (r) uid;
        extraGroups = [ ];
      };
    }) researchers
  );

  adminUser = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" ];
  };
in
pkgs.testers.runNixOSTest {
  name = "shared-cluster";

  nodes = {
    controller =
      { ... }:
      {
        imports = [
          (testlib.mkSlurmMaster {
            hostName = "controller";
            inherit clusterNodes;
          })
        ];
        networking.extraHosts = clusterHosts;
        users.users = mkResearchers // {
          admin = adminUser;
        };
      };

    login =
      { ... }:
      {
        imports = [
          (testlib.mkSlurmSubmit {
            hostName = "login";
            masterHostname = "controller";
            inherit clusterHosts;
          })
        ];
        services.openssh.enable = true;
        users.users = mkResearchers // {
          admin = adminUser;
        };
      };
  }
  // builtins.listToAttrs (
    map
      (i: {
        name = "compute${toString i}";
        value =
          { ... }:
          {
            imports = [
              (testlib.mkSlurmCompute {
                hostName = "compute${toString i}";
                masterHostname = "controller";
                inherit clusterNodes;
                adopt = true;
              })
            ];
            networking.extraHosts = clusterHosts;
            users.users = mkResearchers // {
              admin = adminUser;
            };
          };
      })
      [
        1
        2
        3
        4
      ]
  );

  testScript = ''
    import time

    t0 = time.time()
    def stage(msg):
        print(f"\n========== [t+{time.time() - t0:6.1f}s] {msg} ==========")
    def say(msg):
        print(f"[t+{time.time() - t0:6.1f}s] {msg}")

    compute_nodes = [compute1, compute2, compute3, compute4]
    all_slurm = [controller] + compute_nodes
    all_nodes = all_slurm + [login]
    researchers_list = ["res1", "res2", "res3", "res4"]

    stage("start_all: booting 6 VMs")
    start_all()

    stage("munge + slurmctld + slurmd come up")
    for n, name in [(controller, "controller"), (compute1, "compute1"),
                     (compute2, "compute2"), (compute3, "compute3"),
                     (compute4, "compute4")]:
        n.wait_for_unit("munged.service", timeout=120)
        say(f"munged up on {name}")
    controller.wait_for_unit("slurmctld.service", timeout=120)
    say("slurmctld up on controller")
    for n, name in [(compute1, "compute1"), (compute2, "compute2"),
                     (compute3, "compute3"), (compute4, "compute4")]:
        n.wait_for_unit("slurmd.service", timeout=120)
        say(f"slurmd up on {name}")
    login.wait_for_unit("munged.service", timeout=120)
    login.wait_for_unit("sshd.service", timeout=60)
    say("munged + sshd up on login")

    stage("all 4 compute nodes reach IDLE")
    controller.succeed(
        "for i in $(seq 1 90); do "
        "  idle=$(sinfo -h -N -o '%T' | grep -c idle || true); "
        "  echo \"attempt $i: $idle idle nodes\"; "
        "  if [ \"$idle\" -ge 4 ]; then sinfo -N; exit 0; fi; "
        "  for n in compute1 compute2 compute3 compute4; do "
        "    scontrol update nodename=$n state=resume 2>/dev/null || true; "
        "  done; sleep 2; "
        "done; echo TIMEOUT; sinfo -N; scontrol show nodes; exit 1"
    )
    say("all 4 compute nodes IDLE")

    stage("provision SSH keys on login + push pubkeys to compute")
    for u in researchers_list + ["admin"]:
        login.succeed(
            f"su - {u} -c 'ssh-keygen -t ed25519 -N \"\" -f /home/{u}/.ssh/id_ed25519'"
        )
        pubkey = login.succeed(f"cat /home/{u}/.ssh/id_ed25519.pub").strip()
        for c in compute_nodes:
            c.succeed(
                f"install -d -o {u} -g users -m 0700 /home/{u}/.ssh && "
                f"echo '{pubkey}' > /home/{u}/.ssh/authorized_keys && "
                f"chown {u}: /home/{u}/.ssh/authorized_keys && "
                f"chmod 600 /home/{u}/.ssh/authorized_keys"
            )
        say(f"pubkey for {u} pushed to all compute nodes")

    ssh_opts = (
        "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-o BatchMode=yes -o ConnectTimeout=10"
    )

    stage("INVARIANT 2: researchers reach the login proxy")
    for u in researchers_list:
        with subtest(f"researcher {u} has shell on login"):
            login.succeed(f"su - {u} -c 'true'")
            say(f"OK {u} has interactive shell on login")

    stage("INVARIANT 3: every researcher sbatch lands on compute")
    for u in researchers_list:
        controller.succeed(
            f"su - {u} -c \"sbatch -p compute -N1 -t 00:01:00 "
            f"--wrap='echo $(hostname) > /tmp/{u}.out' -o /tmp/{u}.log\""
        )
        say(f"submitted job for {u}")
    controller.succeed(
        "for i in $(seq 1 90); do "
        "  if ! squeue -h | grep -q .; then echo drained; exit 0; fi; sleep 2; "
        "done; squeue; sacct 2>/dev/null || true; exit 1"
    )
    say("all 4 researcher jobs drained from queue")

    stage("INVARIANT 4: pam_slurm_adopt denies SSH without an allocation")
    for u in researchers_list:
        for c_idx in range(1, 5):
            cmd = (
                f"su - {u} -c \"ssh {ssh_opts} -i /home/{u}/.ssh/id_ed25519 "
                f"{u}@compute{c_idx} true\""
            )
            rc, out = login.execute(cmd, timeout=30)
            assert rc != 0, (
                f"FAIL: {u} SSHed to compute{c_idx} without allocation. "
                f"pam_slurm_adopt didn't deny.\n{out}"
            )
            say(f"OK {u} -> compute{c_idx} DENIED (no allocation)")

    stage("INVARIANT 5: admin (wheel) bypasses pam_slurm_adopt")
    for c_idx in range(1, 5):
        with subtest(f"admin SSHes to compute{c_idx}"):
            login.succeed(
                f"su - admin -c \"ssh {ssh_opts} -i /home/admin/.ssh/id_ed25519 "
                f"admin@compute{c_idx} true\""
            )
            say(f"OK admin -> compute{c_idx} (wheel bypass)")

    stage(f"DONE in {time.time() - t0:.1f}s")
    print("SHARED CLUSTER VERIFICATIONS PASSED")
  '';
}
