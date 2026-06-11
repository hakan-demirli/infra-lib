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
  cephCfg = if fsCfg == null then null else (fsCfg.cephfs or null);
  active = cephCfg != null;
in
{
  config = lib.mkIf active {
    services.ceph = {
      enable = true;
      global = {
        inherit (cephCfg) fsid;
        monHost = lib.concatStringsSep "," cephCfg.monitors;
        monInitialMembers = lib.concatStringsSep "," (
          map (m: lib.head (lib.splitString ":" m)) cephCfg.monitors
        );
        "mon clock drift allowed" = "2.0";
      };
    };

    environment.systemPackages = [ ];
  };
}
