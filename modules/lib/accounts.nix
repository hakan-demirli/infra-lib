{ lib }:
let
  rootEquivalentGroups = [
    "wheel"
    "docker"
    "libvirtd"
    "lxd"
    "incus-admin"
  ];

  tierGrantsRoot =
    tier: accountGroups:
    tier.root_ssh
    || tier.sudo.extra_rule != null
    || lib.any (group: lib.elem group rootEquivalentGroups) (accountGroups ++ tier.groups);

  hasAccountOn =
    hostId: user:
    let
      allowedHosts = user.allowed_hosts or [ "all" ];
    in
    user.system_account != null
    && !(user.archived or false)
    && (lib.elem "all" allowedHosts || lib.elem hostId allowedHosts);

  onHost =
    cluster: hostId:
    let
      grants = lib.filter (
        grant: cluster.users ? ${grant.user} && hasAccountOn hostId cluster.users.${grant.user}
      ) (cluster.usersOnHost.${hostId} or [ ]);
    in
    lib.mapAttrs (
      userId: userGrants:
      let
        account = cluster.users.${userId}.system_account;
        tierIds = lib.unique (map (grant: grant.unix_tier) userGrants);
        tierId =
          if lib.length tierIds == 1 then
            lib.head tierIds
          else
            throw "accounts: host '${hostId}' resolves conflicting Unix tiers for '${userId}': ${lib.concatStringsSep ", " tierIds}";
        tier =
          cluster.unixAccessTiers.${tierId}
            or (throw "accounts: host '${hostId}' grants '${userId}' the undeclared Unix tier '${tierId}'");
        groups = lib.unique (account.groups ++ tier.groups);
      in
      {
        user = userId;
        inherit account groups tier;
        grants = userGrants;
        unix_tier = tierId;
        sudo_capable = lib.elem "wheel" groups || tier.sudo.extra_rule != null;
        root_capable = tierGrantsRoot tier account.groups;
      }
    ) (lib.groupBy (grant: grant.user) grants);
in
{
  inherit rootEquivalentGroups tierGrantsRoot onHost;
}
