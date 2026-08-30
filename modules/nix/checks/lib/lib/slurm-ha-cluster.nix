{ lib, ... }:
let
  cfg = rec {
    clusterName = "ha-test";
    sharedIp = "192.168.1.5";
    ctldAIp = "192.168.1.10";
    ctldBIp = "192.168.1.11";
    compute1Ip = "192.168.1.20";
    compute2Ip = "192.168.1.21";

    nodeNames = [
      "compute-1 NodeAddr=${compute1Ip} CPUs=2 RealMemory=512 State=UNKNOWN"
      "compute-2 NodeAddr=${compute2Ip} CPUs=2 RealMemory=512 State=UNKNOWN"
    ];

    mungeKey = "test-munge-key-test-munge-key-test-munge-key-test-munge-key-1234";

    etcHosts = ''
      ${sharedIp}   shared-state
      ${ctldAIp}    ctld-a
      ${ctldBIp}    ctld-b
      ${compute1Ip} compute-1
      ${compute2Ip} compute-2
    '';

    slurmExtraConfig = ''
      SlurmctldHost=ctld-a(${ctldAIp})
      SlurmctldHost=ctld-b(${ctldBIp})
      SlurmctldTimeout=30
      SlurmdTimeout=180
      SlurmctldPidFile=/run/slurmctld.pid
      SlurmdPidFile=/run/slurmd.pid
      SlurmctldLogFile=/var/log/slurm/slurmctld.log
      SlurmdLogFile=/var/log/slurm/slurmd.log
      AuthType=auth/munge
      CryptoType=crypto/munge
      SchedulerType=sched/backfill
      SelectType=select/cons_tres
      SelectTypeParameters=CR_Core
      ReturnToService=2
      MailProg=/run/current-system/sw/bin/true
    '';

    cgroupConf = ''
      ConstrainCores=yes
      ConstrainRAMSpace=yes
    '';
  };

  sharedStateNode = _: {
    virtualisation = {
      vlans = [ 1 ];
      memorySize = 768;
      cores = 1;
    };
    networking = {
      hostName = lib.mkForce "shared-state";
      useDHCP = false;
      interfaces.eth1.ipv4.addresses = lib.mkOverride 0 [
        {
          address = cfg.sharedIp;
          prefixLength = 24;
        }
      ];
      firewall.enable = false;
      extraHosts = cfg.etcHosts;
    };
    users.users.slurm = {
      uid = 307;
      group = "slurm";
      isSystemUser = true;
    };
    users.groups.slurm.gid = 307;
    services.nfs.server = {
      enable = true;
      exports = ''
        /export 192.168.1.0/24(rw,no_root_squash,no_subtree_check,sync)
      '';
    };
    systemd.tmpfiles.rules = [
      "d /export 0755 slurm slurm -"
    ];
  };

  mkCtldNode =
    { hostname, ip }:
    _: {
      virtualisation = {
        vlans = [ 1 ];
        memorySize = 1280;
        cores = 1;
        fileSystems."/var/spool/slurm-state" = {
          device = "shared-state:/export";
          fsType = "nfs4";
          options = [
            "noatime"
            "vers=4.2"
            "noac"
          ];
        };
      };
      networking = {
        hostName = lib.mkForce hostname;
        useDHCP = false;
        interfaces.eth1.ipv4.addresses = lib.mkOverride 0 [
          {
            address = ip;
            prefixLength = 24;
          }
        ];
        firewall.enable = false;
        extraHosts = cfg.etcHosts;
      };
      services = {
        rpcbind.enable = true;
        munge = {
          enable = true;
          password = "/etc/munge/munge.key";
        };
        slurm = {
          inherit (cfg) clusterName;
          nodeName = cfg.nodeNames;
          partitionName = [
            "test Nodes=compute-[1-2] Default=YES MaxTime=INFINITE State=UP"
          ];
          stateSaveLocation = "/var/spool/slurm-state";
          procTrackType = "proctrack/cgroup";
          server.enable = true;
          extraConfig = cfg.slurmExtraConfig;
          extraCgroupConfig = cfg.cgroupConf;
        };
      };
      systemd = {
        services.slurmctld = {
          wantedBy = lib.mkForce [ ];
          preStart = lib.mkForce ''
            test "$(stat -c %U:%G /var/spool/slurm-state)" = "slurm:slurm"
          '';
          unitConfig.RequiresMountsFor = "/var/spool/slurm-state";
          after = [ "var-spool-slurm\\x2dstate.mount" ];
        };
        tmpfiles.rules = [
          "d /var/log/slurm 0755 slurm slurm -"
        ];
      };
      environment.etc."munge/munge.key" = {
        text = cfg.mungeKey;
        mode = "0400";
        user = "munge";
        group = "munge";
      };
    };

  mkComputeNode =
    { hostname, ip }:
    _: {
      virtualisation = {
        vlans = [ 1 ];
        memorySize = 1280;
        cores = 2;
      };
      networking = {
        hostName = lib.mkForce hostname;
        useDHCP = false;
        interfaces.eth1.ipv4.addresses = lib.mkOverride 0 [
          {
            address = ip;
            prefixLength = 24;
          }
        ];
        firewall.enable = false;
        extraHosts = cfg.etcHosts;
      };
      services.munge = {
        enable = true;
        password = "/etc/munge/munge.key";
      };
      services.slurm = {
        inherit (cfg) clusterName;
        nodeName = cfg.nodeNames;
        partitionName = [
          "test Nodes=compute-[1-2] Default=YES MaxTime=INFINITE State=UP"
        ];
        stateSaveLocation = "/var/spool/slurm-state";
        procTrackType = "proctrack/cgroup";
        client.enable = true;
        extraConfig = cfg.slurmExtraConfig;
        extraCgroupConfig = cfg.cgroupConf;
      };
      systemd = {
        services.slurmd.wantedBy = lib.mkForce [ ];
        tmpfiles.rules = [
          "d /var/log/slurm 0755 slurm slurm -"
        ];
      };
      environment.etc."munge/munge.key" = {
        text = cfg.mungeKey;
        mode = "0400";
        user = "munge";
        group = "munge";
      };
    };

  bootstrapScript = ''
    start_all()

    with subtest("[ha fixture] NFS shared-state up"):
        shared_state.wait_for_unit("nfs-server.service", timeout=120)
        shared_state.succeed("systemctl start network-online.target")
        shared_state.wait_for_unit("network-online.target", timeout=60)

    for n in (ctld_a, ctld_b, compute_1, compute_2):
        n.succeed("systemctl start network-online.target")
        n.wait_for_unit("network-online.target", timeout=60)
        n.wait_for_unit("munged.service", timeout=60)

    with subtest("[ha fixture] mount coherent NFS state on both ctlds"):
        for n in (ctld_a, ctld_b):
            n.wait_for_unit("var-spool-slurm\\x2dstate.mount", timeout=120)
            n.succeed("mountpoint -q /var/spool/slurm-state")
            n.succeed(
                "findmnt -n -o OPTIONS /var/spool/slurm-state | grep -qw noac"
            )

    with subtest("[ha fixture] start primary before backup"):
        ctld_a.succeed("systemctl start slurmctld.service")
        ctld_a.wait_for_unit("slurmctld.service", timeout=180)
        ctld_a.wait_until_succeeds(
            "scontrol ping 2>&1 "
            "| grep -Fq 'Slurmctld(primary) at ctld-a is UP'",
            timeout=120,
        )

        ctld_b.succeed("systemctl start slurmctld.service")
        ctld_b.wait_for_unit("slurmctld.service", timeout=180)
        ctld_a.wait_until_succeeds(
            "scontrol ping 2>&1 "
            "| grep -Fq 'Slurmctld(backup) at ctld-b is UP'",
            timeout=120,
        )

    with subtest("[ha fixture] start computes and require both nodes idle"):
        for compute in (compute_1, compute_2):
            compute.succeed("systemctl start slurmd.service")
            compute.wait_for_unit("slurmd.service", timeout=180)

        for node in ("compute-1", "compute-2"):
            ctld_a.wait_until_succeeds(
                f"scontrol show node {node} -o | grep -q 'State=IDLE'",
                timeout=180,
            )

    def wait_for_backup_takeover():
        ctld_b.wait_until_succeeds(
            "grep -q 'Running as primary controller' "
            "/var/log/slurm/slurmctld.log",
            timeout=180,
        )
  '';

in
{
  inherit
    cfg
    sharedStateNode
    mkCtldNode
    mkComputeNode
    bootstrapScript
    ;
}
