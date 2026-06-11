{
  lib,
  host ? null,
  cluster ? null,
  ...
}:
let
  active = host != null;
in
{
  imports = [ ./ceph-common.nix ];

  config = lib.mkIf active {
    services.ceph.mon = {
      enable = true;
      daemons = [ host.id ];
    };

    networking.firewall = {
      allowedTCPPorts = [
        6789
        3300
      ];
    };

    assertions =
      let
        clusterId = host.cluster or null;
        clusterRec =
          if clusterId == null || cluster == null then null else (cluster.clusters.${clusterId} or null);
        fsCfg = if clusterRec == null then null else (clusterRec.cluster_fs or null);
        cephCfg = if fsCfg == null then null else (fsCfg.cephfs or null);
        monHosts =
          if cephCfg == null then [ ] else map (m: lib.head (lib.splitString ":" m)) cephCfg.monitors;
      in
      [
        {
          assertion = cephCfg == null || lib.elem host.id monHosts;
          message = ''
            ceph-mon: host '${host.id}' imports services/ceph-mon but is
            not listed in cluster.cluster_fs.cephfs.monitors
            (got: ${lib.concatStringsSep "," monHosts}). Add
            '${host.id}:6789' to the monitors list, or drop ceph-mon
            from this host's role modules[].
          '';
        }
      ];
  };
}
