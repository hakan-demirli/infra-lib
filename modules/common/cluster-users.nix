{
  lib,
  config,
  pkgs,
  host,
  cluster,
  ...
}:
with lib;
let
  hid = host.id;
  grants = cluster.usersOnHost.${hid} or [ ];

  unixTierFor =
    tid:
    cluster.unixAccessTiers.${tid} or (throw ''
      cluster-users: host '${hid}' has a grant referencing Unix tier '${tid}' but no such tier is declared.
      Known tiers: ${concatStringsSep ", " (attrNames cluster.unixAccessTiers)}.
    '');

  shellPkg =
    s:
    if s == "bash" then
      pkgs.bashInteractive
    else if s == "zsh" then
      pkgs.zsh
    else if s == "fish" then
      pkgs.fish
    else if s == "nushell" then
      pkgs.nushell
    else
      pkgs.bashInteractive;

  allowedOnThisHost = u: elem "all" u.allowed_hosts || elem hid u.allowed_hosts;

  hostSshTrust = host.ssh_trust or { };
  extraTrustedKeysFor =
    target:
    let
      uids = hostSshTrust.${target} or [ ];
      keysFromUid = uid: (cluster.users.${uid} or { keys.ssh = [ ]; }).keys.ssh;
    in
    concatLists (map keysFromUid uids);

  visibleGrants = filter (
    g:
    cluster.users ? ${g.user}
    && cluster.users.${g.user}.system_account != null
    && !(cluster.users.${g.user}.archived or false)
    && allowedOnThisHost cluster.users.${g.user}
  ) grants;

  grantsByUser = foldl' (
    acc: g:
    let
      uid = g.user;
    in
    acc // { ${uid} = (acc.${uid} or [ ]) ++ [ g ]; }
  ) { } visibleGrants;

  effectiveTier =
    userGrants:
    let
      tierIds = unique (map (g: g.unix_tier) userGrants);
      tierId =
        if length tierIds == 1 then
          head tierIds
        else
          throw "cluster-users: host '${hid}' resolved conflicting Unix tiers: ${concatStringsSep ", " tierIds}";
      tier = unixTierFor tierId;
    in
    {
      inherit (tier) groups root_ssh;
      sudoRule = tier.sudo.extra_rule;
      sshAllowed = tier.ssh.allowed;
    };

  mkUserEntry =
    uid: userGrants:
    let
      u = cluster.users.${uid};
      sa = u.system_account;
      eff = effectiveTier userGrants;
      extraGroupsList = unique (concatLists [
        sa.groups
        eff.groups
      ]);
      homeDir = "/home/${sa.username}";
    in
    nameValuePair sa.username {
      isNormalUser = true;
      inherit (sa) uid;
      home = homeDir;
      shell = shellPkg sa.shell;
      extraGroups = extraGroupsList;
      openssh.authorizedKeys.keys = unique (u.keys.ssh ++ extraTrustedKeysFor sa.username);
      allowedHosts = u.allowed_hosts;
      inherit (u) cohort;
      xrdpAccess = u.xrdp_access;
      inherit (u) expires;
    };

  userEntries = mapAttrs' mkUserEntry grantsByUser;

  sudoLines = concatLists (
    mapAttrsToList (
      uid: userGrants:
      let
        u = cluster.users.${uid};
        sa = u.system_account;
        eff = effectiveTier userGrants;
      in
      optional (eff.sudoRule != null) "${sa.username} ALL=(ALL) ${eff.sudoRule}"
    ) grantsByUser
  );

  usersDeniedSsh = mapAttrsToList (_uid: _grants: _uid) (
    filterAttrs (
      uid: userGrants:
      let
        u = cluster.users.${uid};
        sa = u.system_account;
        eff = effectiveTier userGrants;
      in
      sa != null && !eff.sshAllowed
    ) grantsByUser
  );

  deniedUsernames = map (uid: cluster.users.${uid}.system_account.username) usersDeniedSsh;

  rootAuthorizedKeys = unique (
    concatLists (
      mapAttrsToList (
        uid: userGrants:
        let
          user = cluster.users.${uid};
        in
        if (effectiveTier userGrants).root_ssh && allowedOnThisHost user then user.keys.ssh else [ ]
      ) grantsByUser
    )
    ++ extraTrustedKeysFor "root"
  );

  shellsToEnable = unique (
    mapAttrsToList (uid: _: cluster.users.${uid}.system_account.shell) grantsByUser
  );
in
{
  options = {
    users = {
      withSops = mkOption {
        type = types.bool;
        default = true;
      };
      deletedUsers = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      users = mkOption {
        type = types.attrsOf (
          types.submodule (_: {
            options = {
              allowedHosts = mkOption {
                type = types.listOf types.str;
                default = [ "all" ];
              };
              cohort = mkOption {
                type = types.enum [
                  "staff"
                  "student"
                  "reviewer"
                  "device"
                  "service"
                ];
                default = "staff";
              };
              xrdpAccess = mkOption {
                type = types.bool;
                default = false;
              };
            };
          })
        );
      };
    };
  };

  config = mkMerge [
    {
      users.users =
        userEntries
        // (optionalAttrs (rootAuthorizedKeys != [ ]) {
          root = {
            openssh.authorizedKeys.keys = rootAuthorizedKeys;
          };
        });

      programs.zsh.enable = mkIf (elem "zsh" shellsToEnable) (mkDefault true);
      programs.fish.enable = mkIf (elem "fish" shellsToEnable) (mkDefault true);

      systemd.tmpfiles.rules = map (n: "R /home/${n} - - - - -") config.users.deletedUsers;

      security.sudo.extraConfig = mkIf (sudoLines != [ ]) (concatStringsSep "\n" sudoLines + "\n");

      services.openssh.extraConfig = mkIf (
        deniedUsernames != [ ]
      ) "DenyUsers ${concatStringsSep " " deniedUsernames}\n";

      assertions = flatten (
        mapAttrsToList (name: u: [
          {
            assertion = (u.isSystemUser or false) || u.allowedHosts != [ ];
            message = "User ${name} has empty allowedHosts; pick [\"all\"] or a host list.";
          }
          {
            assertion = (u.isSystemUser or false) || u.cohort != "student" || u.expires != null;
            message = "User ${name} has cohort=student but no expires date.";
          }
        ]) config.users.users
      );
    }
    (mkIf config.users.withSops {
      sops.secrets =
        let
          xrdpUsers = filterAttrs (_: u: u.xrdpAccess) config.users.users;
        in
        mapAttrs' (
          name: _:
          nameValuePair "${name}-password-hash" {
            neededForUsers = true;
          }
        ) xrdpUsers;
    })
  ];
}
