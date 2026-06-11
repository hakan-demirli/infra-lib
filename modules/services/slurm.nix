{
  config,
  lib,
  pkgs,
  host ? null,
  cluster ? null,
  ...
}:
let
  cfg = config.services.slurm-cluster;
  hasMungeSecret = lib.hasAttrByPath [ "sops" "secrets" "munge-key" ] config;
  clusterId =
    if host == null || cluster == null then null else (cluster.hostToCluster.${host.id} or null);
  clusterRec = if clusterId == null then null else (cluster.clusters.${clusterId} or null);
  scheduler = if clusterRec == null then null else clusterRec.scheduler;
  controllers = if scheduler == null then [ ] else scheduler.controllers;
  partitionSpecs = if scheduler == null then { } else scheduler.partitions;
  partitionHosts = lib.unique (
    lib.concatMap (partition: partition.nodes) (lib.attrValues partitionSpecs)
  );
  isMaster = host != null && lib.elem host.id controllers;
  isCompute = host != null && lib.elem host.id partitionHosts;
  masterHostname = if controllers == [ ] then "" else lib.head controllers;

  nodeAttrsFor =
    hostId:
    let
      node = cluster.hosts.${hostId};
    in
    {
      hostName = hostId;
      sockets = node.hardware.cpu_sockets;
      coresPerSocket = node.hardware.cpu_cores_per_socket;
      threadsPerCore = node.hardware.cpu_threads_per_core;
      cpuLogicalCount = node.hardware.cpu_logical_count;
      ramMb = node.hardware.ram_mib;
      features = node.slurm_features;
      gres = node.slurm_gres;
      weight = node.slurm_weight;
    };
  clusterNodes = if clusterRec == null then [ ] else map nodeAttrsFor partitionHosts;
  partitions = lib.mapAttrs (_: partition: {
    inherit (partition) nodes default gres;
    maxTime = partition.max_time;
  }) partitionSpecs;

  fallbackMungeKey = "INSECURE-TEST-KEY-NOT-FOR-PRODUCTION-cluster-config-vm-fallback-${
    lib.concatStrings (lib.genList (_: "X") 64)
  }";
  nodeLine =
    node:
    let
      derived = node.sockets * node.coresPerSocket * node.threadsPerCore;
      cpus = if node.cpuLogicalCount != null then node.cpuLogicalCount else derived;
    in
    lib.concatStringsSep " " (
      [
        node.hostName
        "CPUs=${toString cpus}"
        "Sockets=${toString node.sockets}"
        "CoresPerSocket=${toString node.coresPerSocket}"
        "ThreadsPerCore=${toString node.threadsPerCore}"
        "RealMemory=${toString node.ramMb}"
      ]
      ++ lib.optional (node.features != [ ]) "Feature=${lib.concatStringsSep "," node.features}"
      ++ lib.optional (node.gres != [ ]) "Gres=${lib.concatStringsSep "," node.gres}"
      ++ [
        "Weight=${toString node.weight}"
        "State=UNKNOWN"
      ]
    );
  nodeNameList = map nodeLine clusterNodes;
  nodeNames = map (node: node.hostName) clusterNodes;
  partitionLine =
    name: partition:
    lib.concatStringsSep " " (
      [
        name
        "Nodes=${lib.concatStringsSep "," partition.nodes}"
        "Default=${if partition.default then "YES" else "NO"}"
        "MaxTime=${partition.maxTime}"
      ]
      ++ lib.optional (partition.gres != null) "Gres=${partition.gres}"
      ++ [ "State=UP" ]
    );
  partitionNameList = lib.mapAttrsToList partitionLine partitions;
in
{
  options.services.slurm-cluster = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable SLURM cluster participation (master and/or node)";
    };
    adoptSshSessions = lib.mkOption {
      type = lib.types.bool;
      default = !isMaster;
      description = ''
        Enable pam_slurm_adopt on this host: SSH sessions are accepted only
        when the connecting user has an active slurm allocation on this
        host, and the session is adopted into the job's cgroup. Members of
        `wheel` (admin) bypass.

        Default: true on compute (isMaster = false), false on the master
        (which doesn't run user jobs).
      '';
    };
    allowInsecureTestKey = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Allow the deterministic MUNGE key in isolated tests only.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.enable || (cfg.adoptSshSessions == !isMaster && !cfg.allowInsecureTestKey);
          message = "services.slurm-cluster payload is configured while enable=false.";
        }
      ];
    }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = clusterRec != null && scheduler.kind == "slurm";
          message = "services.slurm-cluster requires the host to belong to an inventory cluster with scheduler.kind=slurm";
        }
        {
          assertion = lib.length controllers == 1;
          message = "services.slurm-cluster currently requires exactly one inventory scheduler controller";
        }
        {
          assertion = isMaster || isCompute;
          message = "services.slurm-cluster is enabled on host '${
            if host == null then "<unknown>" else host.id
          }' which is neither a controller nor a partition node";
        }
        {
          assertion = clusterNodes != [ ];
          message = "services.slurm-cluster requires at least one inventory partition node";
        }
        {
          assertion = partitions != { };
          message = "services.slurm-cluster requires at least one inventory partition";
        }
        {
          assertion = lib.all (partition: lib.all (node: lib.elem node nodeNames) partition.nodes) (
            lib.attrValues partitions
          );
          message = "services.slurm-cluster inventory partition nodes must all exist in the generated node set";
        }
        {
          assertion = lib.length (lib.filter (partition: partition.default) (lib.attrValues partitions)) == 1;
          message = "services.slurm-cluster inventory requires exactly one default partition";
        }
        {
          assertion = hasMungeSecret || cfg.allowInsecureTestKey;
          message = "services.slurm-cluster requires sops.secrets.munge-key; the deterministic key is test-only.";
        }
        {
          assertion = host == null || (host.state or null) != "provisioned" || hasMungeSecret;
          message = "services.slurm-cluster forbids the insecure test MUNGE key on provisioned hosts.";
        }
      ];

      services = {
        timesyncd.enable = true;
        munge.enable = true;

        slurm = {
          server.enable = isMaster;
          client.enable = isCompute;
          controlMachine = masterHostname;
          clusterName = if clusterRec == null then "" else clusterRec.id;
          procTrackType = "proctrack/pgid";

          nodeName = nodeNameList;

          partitionName = partitionNameList;

          extraConfig = ''
            AuthType=auth/munge
            CryptoType=crypto/munge
            SlurmdParameters=config_overrides
          '';
        };
      };

      environment.etc."munge/munge.key" = lib.mkIf (!hasMungeSecret && cfg.allowInsecureTestKey) {
        text = fallbackMungeKey;
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
    })
  ];
}
