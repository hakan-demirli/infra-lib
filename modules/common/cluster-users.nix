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

  granted = filter (
    g: cluster.users ? ${g.user} && !(cluster.users.${g.user}.archived or false)
  ) grants;

  cohortGroups =
    c:
    if c == "admin" then
      [
        "wheel"
        "apptainer"
        "kvm"
        "libvirtd"
        "networkmanager"
        "audio"
        "video"
        "input"
      ]
    else if c == "staff" then
      [
        "users"
        "video"
        "audio"
      ]
    else if c == "student" then
      [ "users" ]
    else if c == "reviewer" then
      [ "users" ]
    else
      [ ];

  tierFor =
    tid:
    cluster.accessTiers.${tid} or (throw ''
      cluster-users: host '${hid}' has a grant referencing tier '${tid}' but no such tier is declared.
      Known tiers: ${concatStringsSep ", " (attrNames cluster.accessTiers)}.
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
      tiers = map (g: tierFor g.tier) userGrants;
      extraGroups = unique (concatLists (map (t: t.extra_groups) tiers));
      sudoStrings = unique (filter (s: s != null) (map (t: t.sudo) tiers));
      sshAllowed = if tiers == [ ] then true else any (t: t.ssh.allowed) tiers;
    in
    {
      inherit extraGroups sudoStrings sshAllowed;
    };

  mkUserEntry =
    uid: userGrants:
    let
      u = cluster.users.${uid};
      sa = u.system_account;
      eff = effectiveTier userGrants;
      extraGroupsList = unique (concatLists [
        sa.groups
        (cohortGroups u.cohort)
        eff.extraGroups
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
      map (s: "${sa.username} ALL=(ALL) ${s}") eff.sudoStrings
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
      map (
        g:
        let
          u = cluster.users.${g.user};
        in
        if u.cohort == "admin" && allowedOnThisHost u then u.keys.ssh else [ ]
      ) granted
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
                  "admin"
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
