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
  researcher = {
    isNormalUser = true;
    uid = 1001;
  };
  nextGeneration.specialisation.next.configuration.services.slurm.extraConfig = ''
    # next generation
  '';
in
pkgs.testers.runNixOSTest {
  name = "slurm-switch-keeps-jobs";

  nodes = {
    controller = {
      imports = [
        (testlib.mkSlurmMaster {
          hostName = "controller";
          inherit clusterNodes;
        })
        nextGeneration
      ];
      networking.extraHosts = clusterHosts;
      users.users.researcher = researcher;
    };
    compute1 = {
      imports = [
        (testlib.mkSlurmCompute {
          hostName = "compute1";
          masterHostname = "controller";
          inherit clusterNodes;
          adopt = false;
        })
        nextGeneration
      ];
      networking.extraHosts = clusterHosts;
      users.users.researcher = researcher;
    };
  };

  testScript =
    { nodes, ... }:
    ''
      def main_pid(machine, unit):
          return machine.succeed(f"systemctl show -p MainPID --value {unit}").strip()

      def job_state(job):
          return controller.succeed(f"scontrol show job {job} | grep -o 'JobState=[A-Z_]*'").strip()

      def switch(machine, toplevel):
          machine.succeed(f"{toplevel}/specialisation/next/bin/switch-to-configuration test")

      start_all()
      controller.wait_for_unit("slurmctld.service")
      compute1.wait_for_unit("slurmd.service")
      controller.wait_until_succeeds("sinfo -h -N -o '%N %T' | grep -q 'compute1 idle'", timeout=120)

      job = controller.succeed(
          "runuser -u researcher -- sbatch --parsable -w compute1 -o /tmp/job.out "
          "--wrap 'echo $$ > /tmp/job.pid; sleep 45; echo finished'"
      ).strip()
      controller.wait_until_succeeds(f"scontrol show job {job} | grep -q JobState=RUNNING", timeout=60)
      compute1.wait_until_succeeds("test -s /tmp/job.pid", timeout=30)
      job_pid = compute1.succeed("cat /tmp/job.pid").strip()

      with subtest("switching a compute node restarts slurmd and keeps the job"):
          slurmd = main_pid(compute1, "slurmd.service")
          switch(compute1, "${nodes.compute1.system.build.toplevel}")
          compute1.wait_for_unit("slurmd.service")
          assert main_pid(compute1, "slurmd.service") not in ("0", slurmd), "slurmd was not restarted"
          compute1.succeed(f"kill -0 {job_pid}")
          assert job_state(job) == "JobState=RUNNING", job_state(job)

      with subtest("switching the controller restarts slurmctld and keeps the job"):
          slurmctld = main_pid(controller, "slurmctld.service")
          switch(controller, "${nodes.controller.system.build.toplevel}")
          controller.wait_for_unit("slurmctld.service")
          assert main_pid(controller, "slurmctld.service") not in ("0", slurmctld), "slurmctld was not restarted"
          compute1.succeed(f"kill -0 {job_pid}")
          controller.wait_until_succeeds(f"scontrol show job {job} | grep -q JobState=RUNNING", timeout=60)

      with subtest("the job completes normally"):
          controller.wait_until_succeeds(f"scontrol show job {job} | grep -q JobState=COMPLETED", timeout=120)
          assert compute1.succeed("tail -n1 /tmp/job.out").strip() == "finished"
          controller.wait_until_succeeds("sinfo -h -N -o '%N %T' | grep -q 'compute1 idle'", timeout=60)
    '';
}
