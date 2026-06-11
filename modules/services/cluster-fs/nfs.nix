{
  lib,
  host ? null,
  cluster ? null,
  ...
}:
let
  clusterId = if host == null then null else (host.cluster or null);
  clusterRec =
    if clusterId == null || cluster == null then null else (cluster.clusters.${clusterId} or null);
  fsCfg = if clusterRec == null then null else (clusterRec.cluster_fs or null);
  nfsCfg = if fsCfg == null then null else (fsCfg.nfs or null);
  active = fsCfg != null && fsCfg.backend == "nfs" && nfsCfg != null;
in
{
  config = lib.mkIf active {
    services.rpcbind.enable = true;

    fileSystems.${fsCfg.mountpoint} = {
      fsType = "nfs4";
      device = "${nfsCfg.server}:${nfsCfg.export}";
      options = [
        "noatime"
        "vers=4.2"
        "x-systemd.requires=network-online.target"
        "x-systemd.after=network-online.target"
        "_netdev"
      ];
    };
  };
}
