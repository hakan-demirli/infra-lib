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
  accounts = (import ../lib/accounts.nix { inherit lib; }).onHost cluster hid;

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

  hostSshTrust = host.ssh_trust or { };
  extraTrustedKeysFor =
    target:
    let
      uids = hostSshTrust.${target} or [ ];
      keysFromUid = uid: (cluster.users.${uid} or { keys.ssh = [ ]; }).keys.ssh;
    in
    concatLists (map keysFromUid uids);

  mkUserEntry =
    uid: entry:
    let
      u = cluster.users.${uid};
      sa = entry.account;
    in
    nameValuePair sa.username {
      isNormalUser = true;
      inherit (sa) uid;
      home = "/home/${sa.username}";
      shell = shellPkg sa.shell;
      extraGroups = entry.groups;
      openssh.authorizedKeys.keys = unique (u.keys.ssh ++ extraTrustedKeysFor sa.username);
      allowedHosts = u.allowed_hosts;
      inherit (u) cohort;
      xrdpAccess = u.xrdp_access;
      inherit (u) expires;
    };

  userEntries = mapAttrs' mkUserEntry accounts;

  sudoLines = concatLists (
    mapAttrsToList (
      _: entry:
      optional (
        entry.tier.sudo.extra_rule != null
      ) "${entry.account.username} ALL=(ALL) ${entry.tier.sudo.extra_rule}"
    ) accounts
  );

  deniedUsernames = map (entry: entry.account.username) (
    filter (entry: !entry.tier.ssh.allowed) (attrValues accounts)
  );

  rootAuthorizedKeys = unique (
    concatLists (
      mapAttrsToList (uid: entry: optionals entry.tier.root_ssh cluster.users.${uid}.keys.ssh) accounts
    )
    ++ extraTrustedKeysFor "root"
  );

  shellsToEnable = unique (mapAttrsToList (_: entry: entry.account.shell) accounts);
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
