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
in
{
  imports = [
    ./cluster-fs/cephfs.nix
    ./cluster-fs/nfs.nix
  ];

  config = lib.mkIf (fsCfg != null) {
    assertions = [
      {
        assertion = fsCfg.backend != "cephfs" || fsCfg.cephfs != null;
        message = ''
          cluster_fs.backend = "cephfs" but cluster_fs.cephfs is null.
          Fill in the cephfs block (fsid, monitors, fs_name) in the
          cluster TOML.
        '';
      }
      {
        assertion = fsCfg.backend != "nfs" || fsCfg.nfs != null;
        message = ''
          cluster_fs.backend = "nfs" but cluster_fs.nfs is null.
          Fill in the nfs block (server, export) in the cluster TOML.
        '';
      }
    ];
  };
}
