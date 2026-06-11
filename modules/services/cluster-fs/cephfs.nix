{
  lib,
  pkgs,
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
  active = fsCfg != null && fsCfg.backend == "cephfs" && cephCfg != null;
in
{
  config = lib.mkIf active {
    boot.kernelModules = [ "ceph" ];

    environment.systemPackages = [ pkgs.ceph ];

    fileSystems.${fsCfg.mountpoint} = {
      fsType = "ceph";
      device = (lib.concatStringsSep "," cephCfg.monitors) + ":/";
      options = [
        "name=${cephCfg.client_name}"
        "fsid=${cephCfg.fsid}"
        "fs=${cephCfg.fs_name}"
        "secretfile=/etc/ceph/ceph.client.${cephCfg.client_name}.keyring"
        "noatime"
        "x-systemd.requires=network-online.target"
        "x-systemd.after=network-online.target"
        "_netdev"
      ];
    };

    networking.firewall.allowedTCPPorts = [
      6789
      3300
    ];
  };
}
