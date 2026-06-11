{
  lib,
  host ? null,
  cluster ? null,
  ...
}:
let
  clusterId =
    if host == null || cluster == null then null else (cluster.hostToCluster.${host.id} or null);
  clusterRec =
    if clusterId == null || cluster == null then null else (cluster.clusters.${clusterId} or null);
  fsCfg = if clusterRec == null then null else (clusterRec.cluster_fs or null);
in
{
  imports = [
    ./cluster-fs/cephfs.nix
    ./cluster-fs/nfs.nix
  ];

  config = lib.mkIf (fsCfg != null) {
    assertions = [
      {
        assertion = fsCfg.backend != "cephfs" || (fsCfg.cephfs != null && fsCfg.nfs == null);
        message = ''
          cluster_fs.backend = "cephfs" requires a non-null cluster_fs.cephfs
          block and cluster_fs.nfs = null.
        '';
      }
      {
        assertion = fsCfg.backend != "nfs" || (fsCfg.nfs != null && fsCfg.cephfs == null);
        message = ''
          cluster_fs.backend = "nfs" requires a non-null cluster_fs.nfs
          block and cluster_fs.cephfs = null.
        '';
      }
    ];
  };
}
