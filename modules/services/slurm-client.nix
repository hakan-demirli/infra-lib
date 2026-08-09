{
  config,
  lib,
  host ? null,
  cluster ? null,
  ...
}:
let
  cfg = config.services.slurm-client;
  hasMungeSecret = lib.hasAttrByPath [ "sops" "secrets" "munge-key" ] config;
  clusterId =
    if host == null || cluster == null then null else (cluster.hostToCluster.${host.id} or null);
  clusterRec = if clusterId == null then null else (cluster.clusters.${clusterId} or null);
  scheduler = if clusterRec == null then null else clusterRec.scheduler;
  controllers = if scheduler == null then [ ] else scheduler.controllers;
  partitionHosts =
    if scheduler == null then
      [ ]
    else
      lib.unique (lib.concatMap (partition: partition.nodes) (lib.attrValues scheduler.partitions));
  masterHostname = if controllers == [ ] then "" else lib.head controllers;
  fallbackMungeKey = "INSECURE-TEST-KEY-NOT-FOR-PRODUCTION-cluster-config-vm-fallback-${
    lib.concatStrings (lib.genList (_: "X") 64)
  }";
in
{
  imports = [ ./munge-sops.nix ];

  options.services.slurm-client = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable SLURM client-only (submit jobs, no execution)";
    };
    allowInsecureTestKey = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Allow the deterministic MUNGE key in isolated tests only.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = clusterRec != null && scheduler.kind == "slurm";
        message = "services.slurm-client requires the host to belong to an inventory cluster with scheduler.kind=slurm";
      }
      {
        assertion = lib.length controllers == 1;
        message = "services.slurm-client currently requires exactly one inventory scheduler controller";
      }
      {
        assertion = host != null && !lib.elem host.id (controllers ++ partitionHosts);
        message = "services.slurm-client is submit-only and cannot be used on an inventory controller or partition node";
      }
      {
        assertion = hasMungeSecret || cfg.allowInsecureTestKey;
        message = "services.slurm-client requires sops.secrets.munge-key; the deterministic key is test-only.";
      }
      {
        assertion = host == null || (host.state or null) != "provisioned" || hasMungeSecret;
        message = "services.slurm-client forbids the insecure test MUNGE key on provisioned hosts.";
      }
    ];

    services = {
      timesyncd.enable = true;
      munge.enable = true;
      slurm = {
        enableStools = true;
        controlMachine = masterHostname;
        clusterName = if clusterRec == null then "" else clusterRec.id;
        extraConfig = ''
          AuthType=auth/munge
          CryptoType=crypto/munge
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
  };
}
