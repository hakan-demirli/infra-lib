{ lib, inventory }:
with lib;
let
  inherit (inventory)
    hosts
    clusters
    teams
    users
    hostToCluster
    hostNodeRoles
    loginNodesOfCluster
    computeNodesOfCluster
    controllerNodesOfCluster
    storageNodesOfCluster
    usersOnCluster
    hostsWithSlurmClient
    ;

  activeClusters = filterAttrs (_: c: c.state != "retired") clusters;

  stripTag = s: if hasPrefix "tag:" s then substring 4 (stringLength s) s else s;

  baseOfCluster =
    cid:
    let
      c = clusters.${cid};
      t = c.network.tailscale_tag or null;
    in
    if t != null then stripTag t else "cluster-${cid}";

  broadTagOf = cid: "tag:${baseOfCluster cid}";

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

  storageTagOf =
    cid:
    let
      base = baseOfCluster cid;
    in
    if (storageNodesOfCluster.${cid} or [ ]) != [ ] then "tag:${base}-storage" else null;

  tagsOfHost =
    hid:
    let
      cid = hostToCluster.${hid} or null;
      nrs = hostNodeRoles.${hid} or [ ];
    in
    if cid == null then
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

  hostTags = mapAttrs (hid: _: tagsOfHost hid) hosts;

  groupsOfUser =
    uid:
    let
      u = users.${uid} or null;
    in
    if u == null then
      [ ]
    else
      (optional u.is_root_anywhere "group:admin")
      ++ map (tid: "group:${tid}") (
        filter (tid: any (m: m.user == uid) (teams.${tid} or { members = [ ]; }).members) (attrNames teams)
      );

  userGroups = mapAttrs (uid: _: groupsOfUser uid) users;

  mkRule = src: dstTag: dstPort: reason: {
    inherit src reason;
    dst = dstTag;
    port = dstPort;
  };

  adminRules = map (cid: mkRule [ "group:admin" ] (broadTagOf cid) "*" "admin") (
    attrNames activeClusters
  );

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
    cid: map (g: mkRule [ g.user ] (loginTagOf cid) "*" "user-grant") clusters.${cid}.access.users
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
    ) c.access.users
  ) (attrNames activeClusters);

  aclRules =
    adminRules
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
      uSelfTags = [ uid ];
      hTags = hostTags.${hid} or [ ];
      srcMatches = rule: any (s: elem s uGroups || elem s uSelfTags) rule.src;
      dstMatches = rule: elem rule.dst hTags && (rule.port == "*" || port == "*" || rule.port == port);
    in
    any (r: srcMatches r && dstMatches r) aclRules;

  canHostReach =
    srcHid: dstHid: port:
    let
      srcTags = hostTags.${srcHid} or [ ];
      dstTagsLocal = hostTags.${dstHid} or [ ];
      srcMatches = rule: any (s: elem s srcTags) rule.src;
      dstMatches =
        rule: elem rule.dst dstTagsLocal && (rule.port == "*" || port == "*" || rule.port == port);
    in
    any (r: srcMatches r && dstMatches r) aclRules;

  clusterAccountGrants = concatLists (
    map (
      hid:
      let
        grants = inventory.usersOnHost.${hid} or [ ];
      in
      map (
        g:
        let
          u = users.${g.user} or null;
          sa = if u == null then null else u.system_account;
        in
        {
          inherit (g) user;
          host = hid;
          account = if sa == null then null else sa.username;
          inherit (g) tier;
          source = if g.via_team == null then "user-grant" else "team:${g.via_team}";
          archived = if u == null then true else u.archived;
        }
      ) grants
    ) (attrNames hosts)
  );

  validAccountGrants = filter (g: g.account != null && !g.archived) clusterAccountGrants;

  rootAnywhereGrants = concatLists (
    map (
      hid:
      let
        grantsHere = filter (g: g.user != null) validAccountGrants;
        rootCandidates = filter (g: g.host == hid && users.${g.user}.is_root_anywhere) grantsHere;
      in
      map (g: {
        inherit (g) user;
        host = hid;
        account = "root";
        tier = "admin";
        source = "is_root_anywhere";
        archived = false;
      }) rootCandidates
    ) (attrNames hosts)
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
            tier = if target == "root" then "admin" else "trust";
            source = "ssh_trust";
            inherit ((users.${uid} or { archived = true; })) archived;
          }) uids
        ) per
      )
    ) (attrNames hosts)
  );

  validTrustGrants = filter (g: !g.archived && users ? ${g.user}) trustGrants;

  sshGrants = validAccountGrants ++ rootAnywhereGrants ++ validTrustGrants;

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
      usersHere = unique (map (e: e.user) (filter (g: g.user != null) (usersOnCluster.${cid} or [ ])));
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
      allowPaths = if intent == null then [ "tailnet" ] else intent.allow_paths;
      requireTailnet = elem "tailnet" allowPaths;
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

  violationsSlurmNoClient = concatMap (
    cid:
    let
      usersHere = unique (map (e: e.user) (filter (g: g.user != null) (usersOnCluster.${cid} or [ ])));
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

  intentViolations = violationsSshNoTailnet ++ violationsSlurmNoTailnet ++ violationsSlurmNoClient;

  errors = filter (v: v.severity == "error") intentViolations;
  warnings = filter (v: v.severity == "warn") intentViolations;

in
{
  inherit
    aclRules
    hostTags
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
