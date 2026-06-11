{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.slurm-cluster;
  nodeLine =
    node:
    let
      derived = node.sockets * node.coresPerSocket * node.threadsPerCore;
      cpus = if node.cpuLogicalCount != null then node.cpuLogicalCount else derived;
    in
    "${node.hostName} "
    + "CPUs=${toString cpus} "
    + "Sockets=${toString node.sockets} "
    + "CoresPerSocket=${toString node.coresPerSocket} "
    + "ThreadsPerCore=${toString node.threadsPerCore} "
    + "RealMemory=${toString node.ramMb} "
    + "State=UNKNOWN";
  nodeNameList = map nodeLine cfg.clusterNodes;

  computeNodes = builtins.filter (node: node.hostName != cfg.masterHostname) cfg.clusterNodes;
  computeNodeNames = lib.concatStringsSep "," (map (node: node.hostName) computeNodes);
in
{
  options.services.slurm-cluster = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable SLURM cluster participation (master and/or node)";
    };
    isMaster = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Is this the SLURM master node?";
    };
    masterHostname = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Hostname of the SLURM master node";
    };
    clusterNodes = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            hostName = lib.mkOption { type = lib.types.str; };
            sockets = lib.mkOption { type = lib.types.ints.positive; };
            coresPerSocket = lib.mkOption { type = lib.types.ints.positive; };
            threadsPerCore = lib.mkOption { type = lib.types.ints.positive; };
            cpuLogicalCount = lib.mkOption {
              type = lib.types.nullOr lib.types.ints.positive;
              default = null;
            };
            ramMb = lib.mkOption { type = lib.types.ints.positive; };
          };
        }
      );
      default = [ ];
    };
    adoptSshSessions = lib.mkOption {
      type = lib.types.bool;
      default = !cfg.isMaster;
      description = ''
        Enable pam_slurm_adopt on this host: SSH sessions are accepted only
        when the connecting user has an active slurm allocation on this
        host, and the session is adopted into the job's cgroup. Members of
        `wheel` (admin) bypass.

        Default: true on compute (isMaster = false), false on the master
        (which doesn't run user jobs).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.masterHostname != "";
        message = "services.slurm-cluster.masterHostname must be set when SLURM is enabled";
      }
      {
        assertion = cfg.clusterNodes != [ ];
        message = "services.slurm-cluster.clusterNodes must be non-empty when SLURM is enabled";
      }
    ];

    services = {
      timesyncd.enable = true;
      munge.enable = true;

      slurm = {
        server.enable = cfg.isMaster;
        client.enable = true;
        controlMachine = cfg.masterHostname;
        clusterName = "nixos-slurm";
        procTrackType = "proctrack/pgid";

        nodeName = nodeNameList;

        partitionName = [
          "master Nodes=${cfg.masterHostname} MaxTime=INFINITE State=UP"
          "compute Nodes=${computeNodeNames} Default=YES MaxTime=INFINITE State=UP"
        ];

        extraConfig = ''
          AuthType=auth/munge
          CryptoType=crypto/munge
          SlurmdParameters=config_overrides
        '';
      };
    };

    environment.etc."munge/munge.key" =
      lib.mkIf (!(lib.hasAttrByPath [ "sops" "secrets" "munge-key" ] config))
        {
          text = "INSECURE-TEST-KEY-NOT-FOR-PRODUCTION-cluster-config-vm-fallback-${
            lib.concatStrings (lib.genList (_: "X") 64)
          }";
          mode = "0400";
          user = "munge";
          group = "munge";
        };

    users.users.slurm = {
      isSystemUser = true;
      group = "slurm";
    };
    users.groups.slurm = { };

    security.pam.services.sshd.rules.account = lib.mkIf cfg.adoptSshSessions {
      "wheel-bypass" = {
        enable = true;
        control = "sufficient";
        modulePath = "${pkgs.linux-pam}/lib/security/pam_succeed_if.so";
        args = [
          "quiet"
          "user"
          "ingroup"
          "wheel"
        ];
        order = 9000;
      };
      "slurm-adopt" = {
        enable = true;
        control = "required";
        modulePath = "${pkgs.slurm}/lib/security/pam_slurm_adopt.so";
        args = [
          "action_no_jobs=deny"
          "action_unknown=deny"
          "action_adopt_failure=deny"
        ];
        order = 9001;
      };
    };
  };
}
