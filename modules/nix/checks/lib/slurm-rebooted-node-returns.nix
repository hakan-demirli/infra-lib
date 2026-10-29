{ pkgs, ... }:
let
  testlib = import ./lib.nix { inherit pkgs; };

  clusterHosts = ''
    192.168.1.1 compute1
    192.168.1.2 controller
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
  ];
  quickTimeout =
    { lib, ... }:
    {
      services.slurm.extraConfig = lib.mkAfter ''
        SlurmdTimeout=10
      '';
    };
in
pkgs.testers.runNixOSTest {
  name = "slurm-rebooted-node-returns";

  nodes = {
    controller = {
      imports = [
        (testlib.mkSlurmMaster {
          hostName = "controller";
          inherit clusterNodes;
        })
        quickTimeout
      ];
      networking.extraHosts = clusterHosts;
    };
    compute1 = {
      imports = [
        (testlib.mkSlurmCompute {
          hostName = "compute1";
          masterHostname = "controller";
          inherit clusterNodes;
          adopt = false;
        })
        quickTimeout
      ];
      networking.extraHosts = clusterHosts;
    };
  };

  testScript = ''
    def boot_time():
        return controller.succeed("scontrol show node compute1 | grep -o 'BootTime=[^ ]*'").strip()

    start_all()
    controller.wait_for_unit("slurmctld.service")
    compute1.wait_for_unit("slurmd.service")
    controller.wait_until_succeeds("sinfo -h -N -n compute1 -o '%T' | grep -qx idle", timeout=120)
    booted = boot_time()

    with subtest("an offline compute node is marked down"):
        compute1.shutdown()
        controller.wait_until_succeeds("sinfo -h -N -n compute1 -o '%T' | grep -q '^down'", timeout=120)

    with subtest("the rebooted compute node registers again"):
        compute1.start()
        compute1.wait_for_unit("slurmd.service")
        controller.wait_until_succeeds(
            f"scontrol show node compute1 | grep -o 'BootTime=[^ ]*' | grep -vxF '{booted}'", timeout=120
        )

    with subtest("the rebooted node returns to service without an operator"):
        controller.wait_until_succeeds("sinfo -h -N -n compute1 -o '%T' | grep -qx idle", timeout=60)
        reason = controller.succeed("sinfo -h -N -n compute1 -o '%E'").strip()
        assert reason == "none", reason
        assert controller.succeed("timeout 60 srun -w compute1 hostname").strip() == "compute1"
  '';
}
