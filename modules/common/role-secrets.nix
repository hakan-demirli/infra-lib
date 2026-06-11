{
  lib,
  self,
  host,
  cluster,
  ...
}:
with lib;
let
  hid = host.id;
  hostRoles = host.roles or [ ];

  walkSource =
    kind: srcId: paths: bucketPath:
    if !(builtins.pathExists bucketPath) then
      [ ]
    else
      mapAttrsToList (name: spec: {
        inherit name spec;
        sourceKind = kind;
        sourceId = srcId;
        bucket = bucketPath;
      }) paths;

  roleEntries =
    roleId:
    let
      role = cluster.roles.${roleId} or null;
      paths = if role == null then { } else (role.secret_paths or { });
    in
    walkSource "role" roleId paths (self + "/secrets/roles/${roleId}.yml");

  hostCluster = cluster.hostToCluster.${hid} or null;
  clusterEntries =
    if hostCluster == null then
      [ ]
    else
      let
        c = cluster.clusters.${hostCluster} or null;
        paths = if c == null then { } else (c.secret_paths or { });
      in
      walkSource "cluster" hostCluster paths (self + "/secrets/clusters/${hostCluster}.yml");

  allEntries = concatLists (map roleEntries hostRoles) ++ clusterEntries;

  byName = foldl' (
    acc: e:
    let
      n = e.name;
      tag = "${e.sourceKind}:${e.sourceId}";
    in
    acc // { ${n} = (acc.${n} or [ ]) ++ [ tag ]; }
  ) { } allEntries;

  collisions = filterAttrs (_: sources: length (unique sources) > 1) byName;

  collisionMessages = mapAttrsToList (
    name: sources:
    "secret '${name}' declared by multiple sources on host '${hid}': "
    + concatStringsSep ", " (unique sources)
  ) collisions;

  mkSopsEntry = entry: {
    inherit (entry) name;
    value = {
      sopsFile = entry.bucket;
      inherit (entry.spec)
        path
        owner
        group
        mode
        ;
      key = entry.spec.source_key;
    };
  };

  sopsEntries = listToAttrs (map mkSopsEntry allEntries);
in
{
  config = mkMerge [
    {
      assertions = map (msg: {
        assertion = false;
        message = msg;
      }) collisionMessages;
    }

    (mkIf (sopsEntries != { }) {
      sops.secrets = sopsEntries;
    })
  ];
}
