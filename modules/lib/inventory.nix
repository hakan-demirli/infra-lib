{
  lib,
  self,
  types,
}:
with lib;
let
  root = self + "/inventory";

  argsModule = {
    _module.args = { inherit lib; };
  };

  evalRaw =
    schemaModule: raw:
    (evalModules {
      modules = [
        argsModule
        schemaModule
        { config = raw; }
      ];
    }).config;

  collectEntityFiles =
    dir:
    if !builtins.pathExists dir then
      [ ]
    else
      let
        go =
          subdir: prefix:
          concatLists (
            mapAttrsToList (
              name: t:
              if t == "directory" then
                go (subdir + "/${name}") "${prefix}${name}/"
              else if t == "regular" && hasSuffix ".nix" name then
                let
                  basename = removeSuffix ".nix" name;
                in
                if hasPrefix "_" basename then
                  [ ]
                else
                  [
                    {
                      relPath = "${prefix}${name}";
                      inherit basename;
                      path = subdir + "/${name}";
                    }
                  ]
              else
                [ ]
            ) (builtins.readDir subdir)
          );
      in
      go dir "";

  loadEntities =
    kind: schemaModule:
    let
      files = collectEntityFiles (root + "/${kind}");
      defaultsPath = root + "/${kind}/_defaults.nix";
      defaultsModules = optional (builtins.pathExists defaultsPath) defaultsPath;

      buildConfig =
        entityPath:
        (evalModules {
          modules = [
            argsModule
            schemaModule
          ]
          ++ defaultsModules
          ++ [ entityPath ];
        }).config;

      entries = map (f: {
        inherit (f) relPath basename;
        config = buildConfig f.path;
      }) files;

      missingId = filter (e: !(e.config ? id) || e.config.id == null) entries;
      mismatched = filter (
        e: (e.config ? id) && e.config.id != null && e.config.id != e.basename
      ) entries;
      byId = foldl' (
        acc: e:
        if !(e.config ? id) || e.config.id == null then
          acc
        else
          acc // { ${e.config.id} = (acc.${e.config.id} or [ ]) ++ [ e ]; }
      ) { } entries;
      duplicates = filterAttrs (_: es: length es > 1) byId;

      errors = concatLists [
        (map (e: "${kind} file 'inventory/${kind}/${e.relPath}' has no 'id' field") missingId)
        (map (
          e:
          "${kind} file 'inventory/${kind}/${e.relPath}' basename '${e.basename}' does not match declared id '${e.config.id}'"
        ) mismatched)
        (mapAttrsToList (
          id: es:
          "${kind} id '${id}' declared in multiple files: ${
            concatStringsSep ", " (map (e: "'inventory/${kind}/${e.relPath}'") es)
          }"
        ) duplicates)
      ];
    in
    if errors != [ ] then
      throw "inventory: ${kind} loader rejected the tree:\n  - ${concatStringsSep "\n  - " errors}"
    else
      listToAttrs (
        map (e: {
          name = e.config.id;
          value = e.config;
        }) entries
      );

  sites = loadEntities "sites" types.siteModule;
  racks = loadEntities "racks" types.rackModule;
  networks = loadEntities "networks" types.networkModule;
  roles = loadEntities "roles" types.roleModule;
  switches = loadEntities "switches" types.switchModule;
  topologies = loadEntities "topologies" types.topologyModule;
  links = loadEntities "links" types.linkModule;
  projects = loadEntities "projects" types.projectModule;
  users = loadEntities "users" types.userModule;
  hosts = loadEntities "hosts" types.hostModule;

  explicitTeams = loadEntities "teams" types.teamModule;
  accessTiers = loadEntities "access-tiers" types.accessTierModule;
  explicitClusters = loadEntities "clusters" types.clusterModule;

  ownerUsers = unique (filter (u: u != null) (mapAttrsToList (_: h: h.ownership.owner) hosts));

  syntheticTeams = listToAttrs (
    concatMap (
      uid:
      let
        tname = "team-${uid}";
      in
      if explicitTeams ? ${tname} then
        [ ]
      else
        [
          {
            name = tname;
            value = evalRaw types.teamModule {
              id = tname;
              description = "Auto-implied personal team for ${uid}";
              members = [
                {
                  user = uid;
                  role = "admin";
                }
              ];
              maintainers = [ uid ];
              labels = {
                synthesised = "true";
              };
            };
          }
        ]
    ) ownerUsers
  );

  teams = explicitTeams // syntheticTeams;

  hostOwnerTeam =
    h:
    if h.ownership.team != null then
      h.ownership.team
    else if h.ownership.owner != null then
      "team-${h.ownership.owner}"
    else
      null;

  hostRoles = h: unique (sort lessThan h.roles);

  hostsByRole = foldl' (
    acc: h: foldl' (acc2: r: acc2 // { ${r} = (acc2.${r} or [ ]) ++ [ h.id ]; }) acc (hostRoles h)
  ) { } (attrValues hosts);

  schedulerHostsOf =
    c: c.scheduler.controllers ++ concatLists (mapAttrsToList (_: p: p.nodes) c.scheduler.partitions);

  effectiveClusterHosts = mapAttrs (
    _cid: c:
    unique (
      c.members.hosts
      ++ concatLists (map (r: hostsByRole.${r} or [ ]) c.members.roles)
      ++ schedulerHostsOf c
    )
  ) explicitClusters;

  hostToClaimedCluster = foldl' (
    acc: cid:
    foldl' (
      acc2: hid: if acc2 ? ${hid} then acc2 else acc2 // { ${hid} = cid; }
    ) acc effectiveClusterHosts.${cid}
  ) { } (attrNames effectiveClusterHosts);

  hostClusterCollisions =
    let
      inverse = foldl' (
        acc: cid:
        foldl' (
          acc2: hid: acc2 // { ${hid} = (acc2.${hid} or [ ]) ++ [ cid ]; }
        ) acc effectiveClusterHosts.${cid}
      ) { } (attrNames effectiveClusterHosts);
      bad = filterAttrs (_: cids: length cids > 1) inverse;
    in
    mapAttrsToList (hid: cids: "host '${hid}' is claimed by multiple clusters: ${toString cids}") bad;

  unclaimedHosts = filterAttrs (hid: _: !(hostToClaimedCluster ? ${hid})) hosts;

  hostStateToClusterState =
    hs:
    if hs == "retired" then
      "retired"
    else if hs == "draining" then
      "draining"
    else if hs == "planned" then
      "planned"
    else
      "active";

  syntheticClusters = mapAttrs' (
    hid: h:
    let
      cid = "cluster-${hid}";
      team = hostOwnerTeam h;
    in
    {
      name = cid;
      value = evalRaw types.clusterModule {
        id = cid;
        description = "Auto-implied personal cluster for ${hid}";
        kind = "personal";
        state = hostStateToClusterState h.state;
        ownership = {
          class = h.ownership.class;
          owner = h.ownership.owner;
          team = if h.ownership.team != null then h.ownership.team else null;
        };
        scheduler = {
          kind = "none";
        };
        members = {
          hosts = [ hid ];
        };
        access = {
          teams =
            if team != null then
              [
                {
                  inherit team;
                  tier = "admin";
                  can_submit_to = [ ];
                }
              ]
            else
              [ ];
          users = [ ];
        };
        network = {
          intra_cluster = "mesh";
          egress = {
            clusters = [ ];
            internet = true;
          };
          ingress = {
            clusters = [ ];
            public = [ ];
          };
          tailscale_tag = "tag:${cid}";
        };
        labels = { };
        synthesised = true;
      };
    }
  ) unclaimedHosts;

  clusters = explicitClusters // syntheticClusters;

  effectiveAllClusterHosts = mapAttrs (
    _cid: c:
    unique (
      c.members.hosts
      ++ concatLists (map (r: hostsByRole.${r} or [ ]) c.members.roles)
      ++ schedulerHostsOf c
    )
  ) clusters;

  hostToCluster = foldl' (
    acc: cid:
    foldl' (
      acc2: hid: if acc2 ? ${hid} then acc2 else acc2 // { ${hid} = cid; }
    ) acc effectiveAllClusterHosts.${cid}
  ) { } (attrNames effectiveAllClusterHosts);

  expandTeamGrant =
    grant:
    let
      t = teams.${grant.team} or null;
      members = if t == null then [ ] else t.members;
      tierFor =
        role:
        if builtins.isString grant.tier then
          grant.tier
        else
          (grant.tier.${role} or (grant.tier.member or "standard"));
    in
    map (m: {
      inherit (m) user;
      tier = tierFor m.role;
      via_team = grant.team;
      via_team_role = m.role;
      inherit (grant) can_submit_to;
    }) members;

  usersOnCluster =
    cid:
    let
      c = clusters.${cid};
      teamGrants = concatLists (map expandTeamGrant c.access.teams);
      userGrants = map (g: {
        inherit (g) user;
        inherit (g) tier;
        via_team = null;
        via_team_role = null;
        inherit (g) can_submit_to;
      }) c.access.users;
      explicitUsers = map (g: g.user) c.access.users;
      teamFiltered = filter (g: !(elem g.user explicitUsers)) teamGrants;
    in
    teamFiltered ++ userGrants;

  usersOnHost =
    hid:
    let
      cid = hostToCluster.${hid} or null;
    in
    if cid == null then [ ] else usersOnCluster cid;

  hostsByCluster = mapAttrs (cid: _: effectiveAllClusterHosts.${cid}) clusters;

  hostCombo =
    h:
    let
      arch = h.hardware.arch;
      rs = concatStringsSep "+" (hostRoles h);
    in
    "${arch}:${rs}";

  hostsByCombo = foldl' (
    acc: h:
    let
      k = hostCombo h;
    in
    acc // { ${k} = (acc.${k} or [ ]) ++ [ h.id ]; }
  ) { } (attrValues hosts);

  comboRepresentatives = mapAttrs (_: head) hostsByCombo;

  ownershipUserRef =
    h: field:
    let
      v = h.ownership.${field};
    in
    optional (
      v != null && !users ? ${v}
    ) "host '${h.id}' ownership.${field} references unknown user '${v}'";

  ownershipTeamRef =
    h:
    let
      v = h.ownership.team;
    in
    optional (
      v != null && !explicitTeams ? ${v}
    ) "host '${h.id}' ownership.team '${v}' is not a declared team";

  ownershipMutex =
    h:
    let
      o = h.ownership.owner != null;
      t = h.ownership.team != null;
    in
    optional (o && t)
      "host '${h.id}' ownership has both owner='${h.ownership.owner}' and team='${h.ownership.team}'; pick one"
    ++ optional (!o && !t) "host '${h.id}' ownership has neither owner nor team; pick one";

  hostOwnershipClassConsistency =
    h:
    optional (
      h.ownership.class == "personal" && h.ownership.owner == null
    ) "host '${h.id}' has ownership.class='personal' but ownership.owner is null";

  hostCpuTopologyConsistency =
    h:
    let
      hw = h.hardware;
      derived = hw.cpu_sockets * hw.cpu_cores_per_socket * hw.cpu_threads_per_core;
      explicit = hw.cpu_logical_count;
    in
    if explicit == null then
      [ ]
    else if explicit == derived then
      [
        "host '${h.id}' hardware.cpu_logical_count=${toString explicit} equals sockets*cores*threads (${toString derived}); drop cpu_logical_count, it is redundant"
      ]
    else if explicit > derived then
      [
        "host '${h.id}' hardware.cpu_logical_count=${toString explicit} exceeds physical topology (sockets*cores*threads=${toString derived}); a CPU cannot have more logical processors than physical threads"
      ]
    else
      [ ];

  hostLocationSiteRef =
    h:
    optional (
      h.location.site != null && !(sites ? ${h.location.site})
    ) "host '${h.id}' location.site references unknown site '${h.location.site}'";

  hostLocationHostRef =
    h:
    optional (
      h.location.kind == "kvm-guest" && h.location.host != null && !(hosts ? ${h.location.host})
    ) "host '${h.id}' location.host references unknown host '${h.location.host}'";

  hostNicNetworkRefs =
    h:
    map (
      n:
      optional (
        !(networks ? ${n.network})
      ) "host '${h.id}' nic[${n.name}].network references unknown network '${n.network}'"
    ) h.nics;

  hostBmcNetworkRef =
    h:
    optional (
      h.bmc != null && !(networks ? ${h.bmc.network})
    ) "host '${h.id}' bmc.network references unknown network '${h.bmc.network}'";

  replacesRef =
    h:
    let
      v = h.replaces;
    in
    if v == null then
      [ ]
    else if !hosts ? ${v} then
      [ "host '${h.id}' replaces unknown host '${v}'" ]
    else if hosts.${v}.state != "retired" then
      [
        "host '${h.id}' replaces '${v}' but that host is in state '${hosts.${v}.state}' (must be 'retired')"
      ]
    else
      [ ];

  hostClusterPinRef =
    h:
    if h.cluster == null then
      [ ]
    else if !(clusters ? ${h.cluster}) then
      [ "host '${h.id}' pins cluster '${h.cluster}' which is not declared" ]
    else if !(elem h.id effectiveAllClusterHosts.${h.cluster}) then
      [ "host '${h.id}' pins cluster '${h.cluster}' but that cluster does not include it" ]
    else
      [ ];

  hostSshTrustRefs =
    h:
    concatLists [
      (concatLists (
        mapAttrsToList (
          target: uids:
          map (
            uid:
            optional (!(users ? ${uid})) "host '${h.id}' ssh_trust.${target} references unknown user '${uid}'"
          ) uids
        ) (h.ssh_trust or { })
      ))
      (map (
        target:
        optional (
          !(h.ssh_trust ? ${target})
        ) "host '${h.id}' ssh_trust_intent.${target} has no matching ssh_trust grant"
      ) (attrNames h.ssh_trust_intent))
    ];

  hostImpermanenceContract =
    h:
    let
      i = h.impermanence;
      supportedLayout = h.disko != null && h.disko.managed && h.disko.layout == "btrfs-lvm";
    in
    concatLists [
      (optional (
        i.enable && !supportedLayout
      ) "host '${h.id}' enables impermanence but does not use managed btrfs-lvm")
      (optional (
        !i.enable && (i.persisted_paths != [ ] || i.persisted_files != [ ] || i.home_mode != "persist-all")
      ) "host '${h.id}' configures impermanence payload while impermanence.enable=false")
    ];

  hostInstallerContract =
    h:
    let
      enabled = h.disko != null && h.disko.installer.enable;
    in
    concatLists [
      (optional (
        enabled && !h.disko.managed
      ) "host '${h.id}' enables its installer while disko.managed=false")
      (optional (
        enabled && h.hardware.os != "linux"
      ) "host '${h.id}' enables its installer but is not a Linux host")
      (optional (
        enabled && !(hasPrefix "/dev/disk/by-id/" h.disko.root_disk)
      ) "host '${h.id}' installer requires a stable /dev/disk/by-id root_disk")
    ];

  hostMonitoringContract =
    h:
    optional (
      !h.monitoring.enabled && h.monitoring.always_on
    ) "host '${h.id}' sets monitoring.always_on=true while monitoring.enabled=false";

  slurmPartitionHosts = unique (
    concatLists (
      mapAttrsToList (
        _: c: concatLists (mapAttrsToList (_: partition: partition.nodes) c.scheduler.partitions)
      ) (filterAttrs (_: c: c.scheduler.kind == "slurm") explicitClusters)
    )
  );

  hostSlurmContract =
    h:
    optional (
      !elem h.id slurmPartitionHosts
      && (h.slurm_features != [ ] || h.slurm_gres != [ ] || h.slurm_weight != 100)
    ) "host '${h.id}' declares Slurm node attributes but is not in a Slurm partition";

  hostVirtContract =
    h:
    let
      v = h.virt;
      hostPayload = v.pool_path != null || v.bridge != null || v.images != { };
      guestPayload = v.image != null || v.cpus != null || v.ram_gb != null || v.disk_gb != null;
      parentId = h.location.host;
      parent = if parentId == null then null else (hosts.${parentId} or null);
      parentVirt = if parent == null then null else parent.virt;
      parentHasImage =
        parentVirt != null
        && parentVirt.role == "host"
        && parentVirt.enable
        && v.image != null
        && parentVirt.images ? ${v.image};
    in
    concatLists [
      (optional (
        v.role == "host" && v.enable && (v.pool_path == null || v.bridge == null)
      ) "host '${h.id}' virt.role=host with virt.enable=true requires pool_path and bridge")
      (optional (
        v.role == "host" && !v.enable && hostPayload
      ) "host '${h.id}' configures virt host payload while virt.enable=false")
      (optional (
        v.role == "host" && guestPayload
      ) "host '${h.id}' virt.role=host cannot declare guest image or resource fields")
      (optional (
        v.role == "guest"
        && (
          v.enable
          || hostPayload
          || v.image == null
          || v.cpus == null
          || v.ram_gb == null
          || v.disk_gb == null
        )
      ) "host '${h.id}' virt.role=guest requires image/cpus/ram_gb/disk_gb and forbids host payload")
      (optional (
        (h.location.kind == "kvm-guest") != (v.role == "guest")
      ) "host '${h.id}' location.kind=kvm-guest must match virt.role=guest")
      (optional (v.role == "guest" && (parentId == null || !parentHasImage))
        "host '${h.id}' virt guest requires an enabled parent virt host containing image '${toString v.image}'"
      )
      (optional (
        (v.enable || v.role == "guest") && h.hardware.arch != "x86_64-linux"
      ) "host '${h.id}' virtualization currently supports only x86_64-linux")
    ];

  hostRoleRefs =
    h: map (r: optional (!roles ? ${r}) "host '${h.id}' references unknown role '${r}'") (hostRoles h);

  hostRolesNonEmpty =
    h:
    optional
      (
        h.roles == [ ]
        && (elem h.hardware.os [
          "linux"
          "darwin"
        ])
      )
      "host '${h.id}' has empty roles[]; every host that builds a closure must compose at least one role";

  teamMemberRefs =
    t:
    map (
      m: optional (!users ? ${m.user}) "team '${t.id}' members references unknown user '${m.user}'"
    ) t.members;

  teamMaintainerRefs =
    t:
    map (
      uid: optional (!users ? ${uid}) "team '${t.id}' maintainers references unknown user '${uid}'"
    ) t.maintainers;

  clusterOwnershipRefs =
    c:
    concatLists [
      (optional (
        c.ownership.owner != null && !users ? ${c.ownership.owner}
      ) "cluster '${c.id}' ownership.owner references unknown user '${c.ownership.owner}'")
      (optional (
        c.ownership.team != null && !teams ? ${c.ownership.team}
      ) "cluster '${c.id}' ownership.team '${c.ownership.team}' is not a declared team")
      (optional (
        c.ownership.owner != null && c.ownership.team != null
      ) "cluster '${c.id}' ownership has both owner and team; pick one")
    ];

  clusterMemberRefs =
    c:
    concatLists [
      (map (
        h: optional (!hosts ? ${h}) "cluster '${c.id}' members.hosts references unknown host '${h}'"
      ) c.members.hosts)
      (map (
        r: optional (!roles ? ${r}) "cluster '${c.id}' members.roles references unknown role '${r}'"
      ) c.members.roles)
    ];

  clusterSchedulerRefs =
    c:
    concatLists [
      (map (
        h: optional (!hosts ? ${h}) "cluster '${c.id}' scheduler.controllers references unknown host '${h}'"
      ) c.scheduler.controllers)
      (concatLists (
        mapAttrsToList (
          partition: p:
          map (
            h:
            optional (
              !(hosts ? ${h})
            ) "cluster '${c.id}' scheduler.partitions.${partition} references unknown host '${h}'"
          ) p.nodes
        ) c.scheduler.partitions
      ))
      (optional
        (c.scheduler.kind != "slurm" && (c.scheduler.controllers != [ ] || c.scheduler.partitions != { }))
        "cluster '${c.id}' has scheduler.kind='${c.scheduler.kind}' but declares Slurm controllers or partitions"
      )
      (optional (
        c.scheduler.kind == "slurm" && c.scheduler.controllers == [ ]
      ) "cluster '${c.id}' has scheduler.kind='slurm' but no controllers")
      (optional (
        c.scheduler.kind == "slurm" && c.scheduler.partitions == { }
      ) "cluster '${c.id}' has scheduler.kind='slurm' but no partitions")
      (optional (
        c.scheduler.kind == "slurm"
        && length (filter (p: p.default) (attrValues c.scheduler.partitions)) != 1
      ) "cluster '${c.id}' must declare exactly one default Slurm partition")
      (mapAttrsToList (
        partition: p:
        optional (p.nodes == [ ]) "cluster '${c.id}' scheduler.partitions.${partition} has no nodes"
      ) c.scheduler.partitions)
    ];

  resolveTierIds = tier: if builtins.isString tier then [ tier ] else attrValues tier;

  clusterAccessRefs =
    c:
    concatLists [
      (map (
        g:
        optional (!teams ? ${g.team}) "cluster '${c.id}' access.teams references unknown team '${g.team}'"
      ) c.access.teams)
      (concatLists (
        map (
          g:
          map (
            t:
            optional (
              !accessTiers ? ${t}
            ) "cluster '${c.id}' access.teams[team=${g.team}] tier '${t}' is not a declared access-tier"
          ) (resolveTierIds g.tier)
        ) c.access.teams
      ))
      (concatLists (
        map (
          g:
          map (
            cs:
            optional (
              !(clusters ? ${cs})
            ) "cluster '${c.id}' access.teams[team=${g.team}].can_submit_to references unknown cluster '${cs}'"
          ) g.can_submit_to
        ) c.access.teams
      ))
      (map (
        g:
        optional (!users ? ${g.user}) "cluster '${c.id}' access.users references unknown user '${g.user}'"
      ) c.access.users)
      (map (
        g:
        optional (
          !accessTiers ? ${g.tier}
        ) "cluster '${c.id}' access.users[user=${g.user}].tier '${g.tier}' is not a declared access-tier"
      ) c.access.users)
      (concatLists (
        map (
          g:
          map (
            cs:
            optional (
              !(clusters ? ${cs})
            ) "cluster '${c.id}' access.users[user=${g.user}].can_submit_to references unknown cluster '${cs}'"
          ) g.can_submit_to
        ) c.access.users
      ))
    ];

  clusterNetworkRefs =
    c:
    concatLists [
      (map (
        cs:
        optional (
          !(clusters ? ${cs})
        ) "cluster '${c.id}' network.egress.clusters references unknown cluster '${cs}'"
      ) c.network.egress.clusters)
      (map (
        cs:
        optional (
          !(clusters ? ${cs})
        ) "cluster '${c.id}' network.ingress.clusters references unknown cluster '${cs}'"
      ) c.network.ingress.clusters)
      (optional (
        c.network.topology != null && !(topologies ? ${c.network.topology})
      ) "cluster '${c.id}' network.topology '${c.network.topology}' is not declared")
      (optional (
        c.network.storage.kind == "none" && c.network.storage.ports_tcp != [ ]
      ) "cluster '${c.id}' declares storage TCP ports while network.storage.kind='none'")
    ];

  clusterFsContract =
    c:
    let
      fs = c.cluster_fs;
    in
    if fs == null then
      [ ]
    else
      concatLists [
        (optional (
          fs.backend == "cephfs" && (fs.cephfs == null || fs.nfs != null)
        ) "cluster '${c.id}' cluster_fs backend=cephfs requires only the cephfs payload")
        (optional (
          fs.backend == "nfs" && (fs.nfs == null || fs.cephfs != null)
        ) "cluster '${c.id}' cluster_fs backend=nfs requires only the nfs payload")
      ];

  clusterParentRef =
    c:
    optional (
      c.parent_cluster != null && !(clusters ? ${c.parent_cluster})
    ) "cluster '${c.id}' parent_cluster '${c.parent_cluster}' is not declared";

  clusterProjectRef =
    c:
    optional (
      c.project != null && !(projects ? ${c.project})
    ) "cluster '${c.id}' project '${c.project}' is not declared";

  networkEgressRefs =
    n:
    optional (
      n.egress.via != null && !hosts ? ${n.egress.via}
    ) "network '${n.id}' egress.via references unknown host '${n.egress.via}'";

  topologyMemberRefs =
    t:
    concatLists [
      (map (
        s: optional (!switches ? ${s}) "topology '${t.id}' spines references unknown switch '${s}'"
      ) t.spines)
      (map (
        s: optional (!switches ? ${s}) "topology '${t.id}' leaves references unknown switch '${s}'"
      ) t.leaves)
      (map (
        s: optional (!switches ? ${s}) "topology '${t.id}' edge references unknown switch '${s}'"
      ) t.edge)
    ];

  switchOwnershipRefs =
    s:
    concatLists [
      (optional (
        s.ownership.owner != null && !(users ? ${s.ownership.owner})
      ) "switch '${s.id}' ownership.owner references unknown user '${s.ownership.owner}'")
      (optional (
        s.ownership.team != null && !(explicitTeams ? ${s.ownership.team})
      ) "switch '${s.id}' ownership.team '${s.ownership.team}' is not a declared team")
      (optional (
        s.ownership.owner != null && s.ownership.team != null
      ) "switch '${s.id}' ownership has both owner and team; pick one")
      (optional (
        s.ownership.owner == null && s.ownership.team == null
      ) "switch '${s.id}' ownership has neither owner nor team; pick one")
      (optional (
        s.ownership.class == "personal" && s.ownership.owner == null
      ) "switch '${s.id}' has ownership.class='personal' but ownership.owner is null")
    ];

  switchLocationRefs =
    s:
    concatLists [
      (optional (
        s.location.kind == "switch-rack" && s.location.rack != null && !(racks ? ${s.location.rack})
      ) "switch '${s.id}' location.rack references unknown rack '${s.location.rack}'")
      (optional (
        s.location.site != null && !(sites ? ${s.location.site})
      ) "switch '${s.id}' location.site references unknown site '${s.location.site}'")
    ];

  switchMgmtNetworkRef =
    s:
    optional (
      s.mgmt_network != null && !(networks ? ${s.mgmt_network})
    ) "switch '${s.id}' mgmt_network references unknown network '${s.mgmt_network}'";

  switchPortPeerRefs =
    s:
    let
      portsWithPeer = filter (p: p.peer != null) (attrValues s.ports);
      isInternal = peer: hosts ? ${peer} || switches ? ${peer};
      isLikelyExternal = peer: hasPrefix "ext-" peer || builtins.match ".*[.].*" peer != null;
    in
    map (
      p:
      optional (!isInternal p.peer && !(isLikelyExternal p.peer))
        "switch '${s.id}' port[${p.name}].peer '${p.peer}' is not a known host or switch (prefix with 'ext-' if external)"
    ) portsWithPeer;

  linkEndpointRefs =
    l:
    let
      checkEnd =
        side: node:
        optional (
          !(hosts ? ${node}) && !(switches ? ${node})
        ) "link '${l.id}' ${side}.node '${node}' is not a known host or switch";
    in
    concatLists [
      (checkEnd "a" l.a.node)
      (checkEnd "b" l.b.node)
    ];

  clusterOwnershipRequired =
    c:
    optional (
      c.ownership.owner == null && c.ownership.team == null
    ) "cluster '${c.id}' ownership has neither owner nor team; pick one";

  projectRefs =
    p:
    concatLists [
      (optional (
        p.sponsor != null && !users ? ${p.sponsor}
      ) "project '${p.id}' sponsor '${p.sponsor}' is not a declared user")
      (map (
        tid: optional (!teams ? ${tid}) "project '${p.id}' teams references unknown team '${tid}'"
      ) p.teams)
      (map (
        uid: optional (!users ? ${uid}) "project '${p.id}' notify references unknown user '${uid}'"
      ) p.notify)
    ];

  studentExpiresAsserts = mapAttrsToList (
    uid: u:
    optional (
      u.cohort == "student" && u.expires == null
    ) "user '${uid}' has cohort='student' but no expires date set"
  ) users;

  badRefs = flatten [
    (mapAttrsToList (
      n: r: optional (!sites ? ${r.site}) "rack '${n}' references unknown site '${r.site}'"
    ) racks)
    (mapAttrsToList (_: hostRoleRefs) hosts)
    (mapAttrsToList (_: hostRolesNonEmpty) hosts)
    (mapAttrsToList (
      n: h:
      optional (
        h.location.kind == "rack" && h.location.rack != null && !racks ? ${h.location.rack}
      ) "host '${n}' references unknown rack '${h.location.rack}'"
    ) hosts)
    (mapAttrsToList (_: h: ownershipUserRef h "owner") hosts)
    (mapAttrsToList (_: h: ownershipUserRef h "operator") hosts)
    (mapAttrsToList (_: h: ownershipUserRef h "custodian") hosts)
    (mapAttrsToList (_: ownershipTeamRef) hosts)
    (mapAttrsToList (_: ownershipMutex) hosts)
    (mapAttrsToList (_: hostOwnershipClassConsistency) hosts)
    (mapAttrsToList (_: hostCpuTopologyConsistency) hosts)
    (mapAttrsToList (_: hostLocationSiteRef) hosts)
    (mapAttrsToList (_: hostLocationHostRef) hosts)
    (mapAttrsToList (_: hostNicNetworkRefs) hosts)
    (mapAttrsToList (_: hostBmcNetworkRef) hosts)
    (mapAttrsToList (_: replacesRef) hosts)
    (mapAttrsToList (_: hostClusterPinRef) hosts)
    (mapAttrsToList (_: hostSshTrustRefs) hosts)
    (mapAttrsToList (_: hostImpermanenceContract) hosts)
    (mapAttrsToList (_: hostInstallerContract) hosts)
    (mapAttrsToList (_: hostMonitoringContract) hosts)
    (mapAttrsToList (_: hostSlurmContract) hosts)
    (mapAttrsToList (_: hostVirtContract) hosts)
    (mapAttrsToList (_: teamMemberRefs) explicitTeams)
    (mapAttrsToList (_: teamMaintainerRefs) explicitTeams)
    (mapAttrsToList (_: clusterOwnershipRefs) explicitClusters)
    (mapAttrsToList (_: clusterOwnershipRequired) explicitClusters)
    (mapAttrsToList (_: clusterMemberRefs) explicitClusters)
    (mapAttrsToList (_: clusterSchedulerRefs) explicitClusters)
    (mapAttrsToList (_: clusterAccessRefs) explicitClusters)
    (mapAttrsToList (_: clusterNetworkRefs) explicitClusters)
    (mapAttrsToList (_: clusterFsContract) explicitClusters)
    (mapAttrsToList (_: clusterParentRef) explicitClusters)
    (mapAttrsToList (_: clusterProjectRef) explicitClusters)
    (mapAttrsToList (_: networkEgressRefs) networks)
    (mapAttrsToList (_: topologyMemberRefs) topologies)
    (mapAttrsToList (_: switchOwnershipRefs) switches)
    (mapAttrsToList (_: switchLocationRefs) switches)
    (mapAttrsToList (_: switchMgmtNetworkRef) switches)
    (mapAttrsToList (_: switchPortPeerRefs) switches)
    (mapAttrsToList (_: linkEndpointRefs) links)
    (mapAttrsToList (_: projectRefs) projects)
    studentExpiresAsserts
    hostClusterCollisions
  ];

  result = {
    inherit
      sites
      racks
      networks
      roles
      users
      hosts
      hostsByRole
      accessTiers
      switches
      topologies
      links
      projects
      ;

    inherit explicitTeams explicitClusters;
    inherit teams;
    inherit clusters;

    inherit
      hostToCluster
      hostsByCluster
      hostsByCombo
      comboRepresentatives
      ;
    hostOwnerTeam = mapAttrs (_: hostOwnerTeam) hosts;
    hostRoles = mapAttrs (_: hostRoles) hosts;
    hostCombo = mapAttrs (_: hostCombo) hosts;
    usersOnHost = mapAttrs (hid: _: usersOnHost hid) hosts;
    usersOnCluster = mapAttrs (cid: _: usersOnCluster cid) clusters;
    activeRoles = attrNames hostsByRole;

    hostNodeRoles = mapAttrs (
      _: h: unique (map (rid: roles.${rid}.node_role or "personal") h.roles)
    ) hosts;

    loginNodesOfCluster = mapAttrs (
      _cid: hids: filter (hid: elem "login" (hostNodeRolesOf hid)) hids
    ) effectiveAllClusterHosts;
    computeNodesOfCluster = mapAttrs (
      _cid: hids: filter (hid: elem "compute" (hostNodeRolesOf hid)) hids
    ) effectiveAllClusterHosts;
    storageNodesOfCluster = mapAttrs (
      _cid: hids: filter (hid: elem "storage" (hostNodeRolesOf hid)) hids
    ) effectiveAllClusterHosts;
    controllerNodesOfCluster = mapAttrs (
      _cid: hids: filter (hid: elem "controller" (hostNodeRolesOf hid)) hids
    ) effectiveAllClusterHosts;

    machineAge = mapAttrs (
      hid: h:
      let
        cid = hostToCluster.${hid} or null;
        clusterKeys = if cid == null then [ ] else (clusters.${cid}.keys.age or [ ]);
      in
      unique (clusterKeys ++ h.keys.age)
    ) hosts;
    machineSsh = mapAttrs (
      hid: h:
      let
        cid = hostToCluster.${hid} or null;
        clusterKeys = if cid == null then [ ] else (clusters.${cid}.keys.ssh or [ ]);
      in
      unique (clusterKeys ++ h.keys.ssh)
    ) hosts;

    slurmClusters = filterAttrs (_: c: c.scheduler.kind == "slurm") clusters;
    hostsBySlurmCluster = mapAttrs (cid: _: effectiveAllClusterHosts.${cid}) (
      filterAttrs (_: c: c.scheduler.kind == "slurm") clusters
    );

    hostsWithSlurmClient =
      let
        slurmClientModules = [
          "services/slurm-client"
          "services/slurm"
        ];
        roleHasSlurmClient =
          rid:
          let
            r = roles.${rid} or null;
            mods = if r == null then [ ] else r.modules;
          in
          any (m: elem m slurmClientModules) mods;
      in
      filter (hid: any roleHasSlurmClient (hostRoles hosts.${hid})) (attrNames hosts);
  };

  hostNodeRolesOf = hid: unique (map (rid: roles.${rid}.node_role or "personal") hosts.${hid}.roles);
in
if badRefs != [ ] then
  throw "inventory cross-references broken:\n  ${concatStringsSep "\n  " badRefs}"
else
  result
