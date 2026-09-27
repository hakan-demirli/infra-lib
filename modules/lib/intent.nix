{ lib, inventory }:
with lib;
let
  inherit (inventory)
    hosts
    clusters
    teams
    users
    hostToCluster
    hostTopologyRoles
    loginNodesOfCluster
    computeNodesOfCluster
    controllerNodesOfCluster
    storageNodesOfCluster
    usersOnCluster
    hostsWithSlurmClient
    ;

  accounts = import ./accounts.nix { inherit lib; };
  activeClusters = filterAttrs (_: c: c.state != "retired") clusters;
  isActiveUser = uid: users ? ${uid} && !(users.${uid}.archived or false);

  stripTag = s: if hasPrefix "tag:" s then substring 4 (stringLength s) s else s;

  baseOfCluster =
    cid:
    let
      c = clusters.${cid};
      t = c.network.tailscale_tag or null;
    in
    if t != null then stripTag t else "cluster-${cid}";

  broadTagOf = cid: "tag:${baseOfCluster cid}";
  fleetAdminTag = "tag:fleet-admin-client";
  metricsTag = "tag:metrics";
  nixCacheTag = "tag:nix-binary-cache";
  deployControllerTag = "tag:fleet-deploy-controller";
  inherit (inventory) deployController;
  fleetServicePorts = {
    logs = 9428;
    nixCache = 5101;
    inbox = 873;
    deployPlan = 5102;
    metricsQuery = 8428;
  };
  adminClientHosts = filter (
    h:
    elem "admin-client" (h.topology_roles or [ ])
    && !(elem h.state [
      "retired"
      "decommissioned"
    ])
  ) (attrValues hosts);
  hasAdminClients = adminClientHosts != [ ];
  exporterPortMap = {
    node = 9100;
    smartctl = 9633;
    ipmi = 9290;
    "lm-sensors" = 9100;
    ceph = 9128;
    slurm = 6817;
    zfs = 9134;
  };
  isMonitoredHost =
    h:
    (h.monitoring.enabled or true)
    && !(elem h.state [
      "retired"
      "decommissioned"
    ]);
  monitoredHosts = filter isMonitoredHost (attrValues hosts);
  monitoringPorts = unique (
    concatMap (
      h:
      filter (port: port != null) (
        map (exporter: exporterPortMap.${exporter} or null) (h.monitoring.exporters or [ ])
      )
    ) monitoredHosts
  );
  userOwnsAdminClient =
    uid:
    any (
      h: (h.ownership.owner or null) == uid || (h.ownership.operator or null) == uid
    ) adminClientHosts;

  loginTagOf =
    cid:
    let
      base = baseOfCluster cid;
    in
    if (loginNodesOfCluster.${cid} or [ ]) != [ ] then "tag:${base}-login" else "tag:${base}";

  computeTagOf =
    cid:
    let
      base = baseOfCluster cid;
    in
    if (computeNodesOfCluster.${cid} or [ ]) != [ ] then "tag:${base}-compute" else null;

  controllerTagOf =
    cid:
    if (controllerNodesOfCluster.${cid} or [ ]) != [ ] then
      "tag:${baseOfCluster cid}-controller"
    else
      null;

  storageTagOf =
    cid:
    let
      base = baseOfCluster cid;
    in
    if (storageNodesOfCluster.${cid} or [ ]) != [ ] then "tag:${base}-storage" else null;

  policyTagsOfHost =
    hid:
    let
      cid = hostToCluster.${hid} or null;
      nrs = hostTopologyRoles.${hid} or [ ];
      roleTags =
        if elem "admin-client" nrs then
          [ fleetAdminTag ]
        else if cid == null then
          [ ]
        else
          let
            base = baseOfCluster cid;
            sub =
              role:
              (
                if role == "login" && (loginNodesOfCluster.${cid} or [ ]) != [ ] then
                  "tag:${base}-login"
                else if role == "compute" && (computeNodesOfCluster.${cid} or [ ]) != [ ] then
                  "tag:${base}-compute"
                else if role == "storage" && (storageNodesOfCluster.${cid} or [ ]) != [ ] then
                  "tag:${base}-storage"
                else if role == "controller" && (controllerNodesOfCluster.${cid} or [ ]) != [ ] then
                  "tag:${base}-controller"
                else
                  null
              );
          in
          unique ([ (broadTagOf cid) ] ++ filter (t: t != null) (map sub nrs));
      clusterHasController = cid != null && (controllerNodesOfCluster.${cid} or [ ]) != [ ];
    in
    roleTags
    ++ optional (isMonitoredHost hosts.${hid}) metricsTag
    ++ optional clusterHasController nixCacheTag
    ++ optional (hid == deployController) deployControllerTag;

  hostPolicyTags = mapAttrs (hid: _: policyTagsOfHost hid) hosts;

  groupsOfUser =
    uid:
    let
      u = users.${uid} or null;
    in
    if u == null || (u.archived or false) then
      [ ]
    else
      (optional (elem "tailnet" u.admin_scopes) "group:admin")
      ++ map (tid: "group:${tid}") (
        filter (tid: any (m: m.user == uid) (teams.${tid} or { members = [ ]; }).members) (attrNames teams)
      );

  userGroups = mapAttrs (uid: _: groupsOfUser uid) users;

  mkRule = src: dstTag: dstPort: reason: {
    inherit src reason;
    dst = dstTag;
    port = dstPort;
  };

  adminRules = map (
    cid:
    mkRule [ (if hasAdminClients then fleetAdminTag else "group:admin") ] (broadTagOf cid) "*" "admin"
  ) (attrNames activeClusters);

  monitoringRules = concatMap (
    cid:
    let
      controllerTag = controllerTagOf cid;
    in
    if controllerTag == null then
      [ ]
    else
      map (port: mkRule [ controllerTag ] metricsTag (toString port) "monitoring") monitoringPorts
  ) (attrNames activeClusters);

  logsRules = concatMap (
    cid:
    let
      controllerTag = controllerTagOf cid;
    in
    optional (controllerTag != null) (
      mkRule [ (broadTagOf cid) ] controllerTag (toString fleetServicePorts.logs) "logs"
    )
  ) (attrNames activeClusters);

  nixCacheRules = concatMap (
    cid:
    let
      controllerTag = controllerTagOf cid;
    in
    optional (controllerTag != null) (
      mkRule [ nixCacheTag ] controllerTag (toString fleetServicePorts.nixCache) "nix-cache"
    )
  ) (attrNames activeClusters);

  inboxRules = concatMap (
    cid:
    let
      senders = filter (t: t != null) [
        (controllerTagOf cid)
        (computeTagOf cid)
      ];
    in
    optional (hasAdminClients && senders != [ ]) (
      mkRule senders fleetAdminTag (toString fleetServicePorts.inbox) "inbox"
    )
  ) (attrNames activeClusters);

  deployRules = optionals (deployController != null) (
    [
      (mkRule [ metricsTag ] deployControllerTag (toString fleetServicePorts.deployPlan) "deploy-plan")
      (mkRule [ nixCacheTag ] deployControllerTag (toString fleetServicePorts.nixCache) "deploy-cache")
    ]
    ++ concatMap (
      cid:
      let
        controllerTag = controllerTagOf cid;
      in
      optional (controllerTag != null) (
        mkRule [ deployControllerTag ] controllerTag (toString fleetServicePorts.metricsQuery) "deploy-gate"
      )
    ) (attrNames activeClusters)
  );

  slurmPorts = import ./slurm-ports.nix;
  slurmSubmitHostsOf = cid: filter (hid: (hostToCluster.${hid} or null) == cid) hostsWithSlurmClient;
  slurmRules = concatMap (
    cid:
    let
      broad = broadTagOf cid;
      controllerTag = controllerTagOf cid;
      ct = computeTagOf cid;
      submitTags = [
        broad
      ]
      ++ optional (any (hid: elem "admin-client" (hostTopologyRoles.${hid} or [ ])) (
        slurmSubmitHostsOf cid
      )) fleetAdminTag;
      daemonTags = filter (t: t != null) [
        controllerTag
        ct
      ];
    in
    optional (controllerTag != null) (
      mkRule [ broad ] controllerTag (toString slurmPorts.controller) "slurmctld"
    )
    ++ optional (ct != null) (mkRule [ broad ] ct (toString slurmPorts.node) "slurmd")
    ++ optionals (daemonTags != [ ]) (
      map (tag: mkRule daemonTags tag slurmPorts.srun "srun") submitTags
    )
  ) (attrNames slurmClusters);

  hostOwners =
    hid:
    let
      inherit (hosts.${hid}) ownership;
      team = if ownership.team == null then null else teams.${ownership.team} or null;
    in
    optional (ownership.owner != null) ownership.owner
    ++ optionals (team != null) (map (m: m.user) (filter (m: m.role == "admin") team.members));

  hostTrusted =
    hid:
    let
      owners = hostOwners hid;
    in
    all (entry: !entry.root_capable || elem entry.user owners) (
      attrValues (accounts.onHost inventory hid)
    )
    && all (uid: elem uid owners) (hosts.${hid}.ssh_trust.root or [ ]);

  deployDependencies =
    hid:
    let
      cid = hostToCluster.${hid} or null;
      c = if cid == null then null else clusters.${cid};
      controllers = if c == null || c.scheduler.kind != "slurm" then [ ] else c.scheduler.controllers;
      partitionNodes = concatMap (p: p.nodes) (attrValues (c.scheduler.partitions or { }));
      usesSlurm = elem hid partitionNodes || elem hid hostsWithSlurmClient;
    in
    optionals (usesSlurm && !elem hid controllers) (
      filter (d: elem d inventory.deployableHosts) controllers
    );

  deployPlan = {
    controller = deployController;
    hosts = genAttrs (filter (hid: isMonitoredHost hosts.${hid}) inventory.deployableHosts) (
      hid:
      let
        system = hosts.${hid}.hardware.arch;
      in
      {
        inherit (hosts.${hid}.deploy) wave hold;
        inherit system;
        after = deployDependencies hid;
        trusted = hostTrusted hid;
        cache =
          deployController != null
          && elem nixCacheTag (policyTagsOfHost hid)
          && system == hosts.${deployController}.hardware.arch;
      }
    );
  };

  meshRules = concatMap (
    cid:
    let
      ct = computeTagOf cid;
      c = clusters.${cid};
    in
    optional (ct != null && c.network.intra_cluster == "mesh") (mkRule [ ct ] ct "*" "compute-mesh")
  ) (attrNames activeClusters);

  loginToComputeRules = concatMap (
    cid:
    let
      ct = computeTagOf cid;
      haveLogin = (loginNodesOfCluster.${cid} or [ ]) != [ ];
    in
    optional (haveLogin && ct != null) (
      mkRule [ "tag:${baseOfCluster cid}-login" ] ct "22" "login-to-compute"
    )
  ) (attrNames activeClusters);

  computeToStorageRulesIntra = concatMap (
    cid:
    let
      ct = computeTagOf cid;
      st = storageTagOf cid;
      ports = clusters.${cid}.network.storage.ports_tcp;
    in
    if ct == null || st == null then
      [ ]
    else
      map (p: mkRule [ ct ] st (toString p) "compute-storage-intra") ports
  ) (attrNames activeClusters);

  computeToStorageRulesInter = concatMap (
    cid:
    let
      ct = computeTagOf cid;
    in
    if ct == null then
      [ ]
    else
      concatMap (
        otherCid:
        if !(clusters ? ${otherCid}) then
          [ ]
        else
          let
            other = clusters.${otherCid};
            st = storageTagOf otherCid;
            ports = other.network.storage.ports_tcp;
          in
          if st == null then [ ] else map (p: mkRule [ ct ] st (toString p) "compute-storage-inter") ports
      ) clusters.${cid}.network.egress.clusters
  ) (attrNames activeClusters);

  teamGrantRules = concatMap (
    cid:
    map (g: mkRule [ "group:${g.team}" ] (loginTagOf cid) "*" "team-grant") clusters.${cid}.access.teams
  ) (attrNames activeClusters);

  userGrantRules = concatMap (
    cid:
    map (g: mkRule [ g.user ] (loginTagOf cid) "*" "user-grant") (
      filter (g: isActiveUser g.user) clusters.${cid}.access.users
    )
  ) (attrNames activeClusters);

  egressClusterRules = concatMap (
    cid:
    let
      c = clusters.${cid};
    in
    concatMap (
      otherCid:
      if !(clusters ? ${otherCid}) then
        [ ]
      else
        map (g: mkRule [ "group:${g.team}" ] (loginTagOf otherCid) "*" "egress-cluster") c.access.teams
    ) c.network.egress.clusters
  ) (attrNames activeClusters);

  teamSubmitRules = concatMap (
    cid:
    let
      c = clusters.${cid};
    in
    concatMap (
      g:
      map (otherCid: mkRule [ "group:${g.team}" ] (loginTagOf otherCid) "*" "team-submit") g.can_submit_to
    ) c.access.teams
  ) (attrNames activeClusters);

  userSubmitRules = concatMap (
    cid:
    let
      c = clusters.${cid};
    in
    concatMap (
      g: map (otherCid: mkRule [ g.user ] (loginTagOf otherCid) "*" "user-submit") g.can_submit_to
    ) (filter (g: isActiveUser g.user) c.access.users)
  ) (attrNames activeClusters);

  aclRules =
    adminRules
    ++ monitoringRules
    ++ logsRules
    ++ nixCacheRules
    ++ inboxRules
    ++ deployRules
    ++ slurmRules
    ++ meshRules
    ++ loginToComputeRules
    ++ computeToStorageRulesIntra
    ++ computeToStorageRulesInter
    ++ teamGrantRules
    ++ userGrantRules
    ++ egressClusterRules
    ++ teamSubmitRules
    ++ userSubmitRules;

  canUserReach =
    uid: hid: port:
    let
      uGroups = userGroups.${uid} or [ ];
      uSelfTags = [ uid ] ++ optional (userOwnsAdminClient uid) fleetAdminTag;
      hTags = hostPolicyTags.${hid} or [ ];
      srcMatches = rule: any (s: elem s uGroups || elem s uSelfTags) rule.src;
      dstMatches = rule: elem rule.dst hTags && (rule.port == "*" || port == "*" || rule.port == port);
    in
    any (r: srcMatches r && dstMatches r) aclRules;

  canHostReach =
    srcHid: dstHid: port:
    let
      srcTags = hostPolicyTags.${srcHid} or [ ];
      dstTagsLocal = hostPolicyTags.${dstHid} or [ ];
      srcMatches = rule: any (s: elem s srcTags) rule.src;
      dstMatches =
        rule: elem rule.dst dstTagsLocal && (rule.port == "*" || port == "*" || rule.port == port);
    in
    any (r: srcMatches r && dstMatches r) aclRules;

  validAccountGrants = concatLists (
    map (
      hid:
      concatLists (
        mapAttrsToList (
          _: entry:
          map (grant: {
            inherit (grant) user unix_tier;
            host = hid;
            account = entry.account.username;
            source = if grant.via_team == null then "user-grant" else "team:${grant.via_team}";
            archived = false;
          }) entry.grants
        ) (accounts.onHost inventory hid)
      )
    ) (attrNames hosts)
  );

  tierRootGrants =
    map
      (
        grant:
        grant
        // {
          account = "root";
          source = "unix-tier:${grant.unix_tier}";
        }
      )
      (
        filter (
          grant: (inventory.unixAccessTiers.${grant.unix_tier} or { root_ssh = false; }).root_ssh
        ) validAccountGrants
      );

  trustGrants = concatLists (
    map (
      hid:
      let
        h = hosts.${hid};
        per = h.ssh_trust;
      in
      concatLists (
        mapAttrsToList (
          target: uids:
          map (uid: {
            user = uid;
            host = hid;
            account = target;
            unix_tier = null;
            source = "ssh_trust";
            inherit ((users.${uid} or { archived = true; })) archived;
          }) uids
        ) per
      )
    ) (attrNames hosts)
  );

  validTrustGrants = filter (g: !g.archived && users ? ${g.user}) trustGrants;

  sshGrants = validAccountGrants ++ tierRootGrants ++ validTrustGrants;

  slurmClusters = filterAttrs (_: c: c.scheduler.kind == "slurm") activeClusters;

  hostsCanSubmitForUser =
    uid:
    filter (
      hid:
      any (
        g: g.user == uid && g.host == hid && g.account != null && g.account != "root"
      ) validAccountGrants
    ) hostsWithSlurmClient;

  slurmSubmitGrants = concatMap (
    cid:
    let
      c = slurmClusters.${cid};
      usersHere = unique (
        map (e: e.user) (filter (g: g.user != null && isActiveUser g.user) (usersOnCluster.${cid} or [ ]))
      );
    in
    concatMap (
      uid:
      let
        sources = hostsCanSubmitForUser uid;
      in
      concatMap (
        srcHid:
        map (ctrl: {
          user = uid;
          fromHost = srcHid;
          toCluster = cid;
          controller = ctrl;
        }) c.scheduler.controllers
      ) sources
    ) usersHere
  ) (attrNames slurmClusters);

  violationsSshNoTailnet = concatMap (
    g:
    let
      h = hosts.${g.host};
      intent = h.ssh_trust_intent.${g.account} or null;
      requireTailnet =
        if intent == null then
          !(elem "admin-client" (h.topology_roles or [ ]))
        else
          elem "tailnet" intent.allow_paths;
      reachable = canUserReach g.user g.host "22";
    in
    if requireTailnet && !reachable then
      [
        {
          kind = "ssh-no-tailnet";
          severity = "error";
          message = "user '${g.user}' has account '${g.account}' on host '${g.host}' (source=${g.source}) but no headscale ACL rule reaches that host on :22";
          inherit (g) user;
          inherit (g) host;
          inherit (g) account;
          inherit (g) source;
        }
      ]
    else
      [ ]
  ) sshGrants;

  violationsSlurmNoTailnet = concatMap (
    sg:
    if !(canUserReach sg.user sg.controller "*") then
      [
        {
          kind = "slurm-no-tailnet";
          severity = "error";
          message = "user '${sg.user}' can submit to cluster '${sg.toCluster}' from '${sg.fromHost}' but cannot reach slurmctld host '${sg.controller}' via headscale";
          inherit (sg) user;
          host = sg.controller;
          inherit (sg) fromHost toCluster;
        }
      ]
    else
      [ ]
  ) slurmSubmitGrants;

  slurmDaemonPaths = concatMap (
    cid:
    let
      inherit (slurmClusters.${cid}.scheduler) controllers partitions;
      nodes = unique (concatMap (p: p.nodes) (attrValues partitions));
      submitHosts = slurmSubmitHostsOf cid;
      paths =
        purpose: port: sources: targets:
        concatMap (
          src:
          map (dst: {
            inherit
              cid
              purpose
              port
              src
              dst
              ;
          }) targets
        ) sources;
    in
    paths "slurmctld" (toString slurmPorts.controller) (unique (nodes ++ submitHosts)) controllers
    ++ paths "slurmd" (toString slurmPorts.node) (unique (controllers ++ submitHosts)) nodes
    ++ paths "srun" slurmPorts.srun (unique (controllers ++ nodes)) submitHosts
  ) (attrNames slurmClusters);

  violationsSlurmDaemons = map (p: {
    kind = "slurm-daemon-no-tailnet";
    severity = "error";
    message = "slurm cluster '${p.cid}': '${p.src}' cannot reach ${p.purpose} on '${p.dst}' port ${p.port} via headscale";
    host = p.dst;
    inherit (p) src port;
    cluster = p.cid;
  }) (filter (p: p.src != p.dst && !canHostReach p.src p.dst p.port) slurmDaemonPaths);

  violationsSlurmNoClient = concatMap (
    cid:
    let
      usersHere = unique (
        map (e: e.user) (filter (g: g.user != null && isActiveUser g.user) (usersOnCluster.${cid} or [ ]))
      );
      noClient = filter (uid: hostsCanSubmitForUser uid == [ ]) usersHere;
    in
    map (uid: {
      kind = "slurm-no-client-host";
      severity = "warn";
      message = "user '${uid}' is granted access to slurm cluster '${cid}' but has no UNIX account on any host that installs services/slurm-client; they can't sbatch from anywhere";
      user = uid;
      cluster = cid;
    }) noClient
  ) (attrNames slurmClusters);

  violationsUntrustedCache = map (hid: {
    kind = "untrusted-cache-client";
    severity = "error";
    message = "host '${hid}' can read the fleet binary caches but grants root to users who do not own it";
    host = hid;
  }) (filter (hid: elem nixCacheTag (policyTagsOfHost hid) && !hostTrusted hid) (attrNames hosts));

  intentViolations =
    violationsSshNoTailnet
    ++ violationsSlurmNoTailnet
    ++ violationsSlurmDaemons
    ++ violationsSlurmNoClient
    ++ violationsUntrustedCache;

  errors = filter (v: v.severity == "error") intentViolations;
  warnings = filter (v: v.severity == "warn") intentViolations;

in
{
  inherit
    aclRules
    deployPlan
    hostPolicyTags
    userGroups
    sshGrants
    slurmSubmitGrants
    intentViolations
    errors
    warnings
    canUserReach
    canHostReach
    ;
}
