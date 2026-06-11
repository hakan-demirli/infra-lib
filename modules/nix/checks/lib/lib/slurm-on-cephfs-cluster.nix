{ pkgs, lib }:
let
  ceph = import ./ceph-cluster.nix { inherit pkgs lib; };

  cfgSlurm = {
    masterHostname = "storage-c";
    compute1Ip = "192.168.1.10";
    compute2Ip = "192.168.1.11";
    nodeAddrs = {
      "storage-c" = ceph.cfg.monC.ip;
      "compute-1" = "192.168.1.10";
      "compute-2" = "192.168.1.11";
    };
    clusterNodes = [
      {
        hostName = "storage-c";
        sockets = 1;
        coresPerSocket = 2;
        threadsPerCore = 1;
        ramMb = 512;
      }
      {
        hostName = "compute-1";
        sockets = 1;
        coresPerSocket = 2;
        threadsPerCore = 1;
        ramMb = 512;
      }
      {
        hostName = "compute-2";
        sockets = 1;
        coresPerSocket = 2;
        threadsPerCore = 1;
        ramMb = 512;
      }
    ];
  };

  slurmTestExtra = ''
    JobRequeue=0
  '';
  slurmTestCgroup = ''
    ConstrainCores=yes
    ConstrainRAMSpace=yes
  '';

  slurmNodeList = [
    "storage-c NodeAddr=${cfgSlurm.nodeAddrs."storage-c"} CPUs=2 Boards=1 Sockets=2 CoresPerSocket=1 ThreadsPerCore=1 RealMemory=512 State=UNKNOWN"
    "compute-1 NodeAddr=${cfgSlurm.nodeAddrs."compute-1"} CPUs=2 Boards=1 Sockets=2 CoresPerSocket=1 ThreadsPerCore=1 RealMemory=512 State=UNKNOWN"
    "compute-2 NodeAddr=${cfgSlurm.nodeAddrs."compute-2"} CPUs=2 Boards=1 Sockets=2 CoresPerSocket=1 ThreadsPerCore=1 RealMemory=512 State=UNKNOWN"
  ];

  slurmAdditions =
    { isMaster }:
    {
      imports = [ ../../../../services/slurm.nix ];
      services = {
        slurm-cluster = {
          enable = true;
          inherit isMaster;
          inherit (cfgSlurm) masterHostname clusterNodes;
          adoptSshSessions = false;
        };
        timesyncd.enable = lib.mkForce false;
        openssh.enable = true;
        slurm = {
          extraConfig = lib.mkAfter slurmTestExtra;
          extraCgroupConfig = slurmTestCgroup;
          procTrackType = lib.mkForce "proctrack/cgroup";
          controlAddr = lib.mkForce cfgSlurm.nodeAddrs."storage-c";
          nodeName = lib.mkForce slurmNodeList;
        };
      };
    };

  storageCNode =
    { lib, ... }:
    {
      imports = [
        ceph.storageCNode
        (slurmAdditions { isMaster = true; })
      ];
      networking.hostName = lib.mkForce "storage-c";
    };

  mkComputeNode =
    { ip, hostName }:
    { lib, ... }:
    {
      imports = [
        (ceph.mkClientNode ip)
        (slurmAdditions { isMaster = false; })
      ];
      networking.hostName = lib.mkForce hostName;
      virtualisation = {
        memorySize = lib.mkForce 1536;
        cores = lib.mkForce 2;
      };
    };

  bootstrapScript = ''
    ${ceph.bootstrapScript}

    ${ceph.mkClientMount "storage_c"}
    ${ceph.mkClientMount "compute_1"}
    ${ceph.mkClientMount "compute_2"}

    with subtest("[fixture] slurmctld + slurmd reach idle"):
        storage_c.wait_for_unit("slurmctld.service", timeout=180)
        compute_1.wait_for_unit("slurmd.service", timeout=180)
        compute_2.wait_for_unit("slurmd.service", timeout=180)
        storage_c.wait_until_succeeds(
            "sinfo -h -o '%T' | grep -v -E '(down|drain|unknown)' | head -1",
            timeout=180,
        )

    with subtest("[fixture] /mnt/ceph is writable by the slurm user"):
        compute_1.succeed("chmod 0777 /mnt/ceph")
  '';

in
{
  inherit (ceph) storageANode storageBNode;
  inherit storageCNode mkComputeNode bootstrapScript;
  cfg = ceph.cfg // {
    inherit (cfgSlurm) compute1Ip compute2Ip masterHostname;
  };
}
