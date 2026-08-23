{
  lib,
  pkgs,
  host ? null,
  cluster ? { },
  ...
}:
let
  hostImpermanence = if host == null then null else (host.impermanence or null);
  enabled =
    hostImpermanence != null
    && (hostImpermanence.enable or false)
    && (hostImpermanence.home_mode or "persist-all") == "user-managed";

  grants = if host == null then [ ] else (cluster.usersOnHost.${host.id} or [ ]);
  eligibleGrants = lib.filter (
    grant:
    (cluster.users.${grant.user} or null) != null
    && cluster.users.${grant.user}.system_account != null
    && !(cluster.users.${grant.user}.archived or false)
  ) grants;
  eligibleUsers = map (grant: cluster.users.${grant.user}.system_account) eligibleGrants;

  persistentRoot = "/persist/home";
  temporaryRoot = "/volatile/home";
  loginUnits = [
    "systemd-user-sessions.service"
    "display-manager.service"
    "sshd.service"
    "linger-users.service"
  ];

  directory =
    path: user: group: mode:
    lib.nameValuePair path {
      d = { inherit user group mode; };
    };

  userDirectories =
    user:
    let
      inherit (user) username;
      owner = username;
      group = "users";
      persistent = "${persistentRoot}/${username}";
      temporary = "${temporaryRoot}/${username}";
      roots = [
        "${persistent}/root"
        "${temporary}/root"
      ];
    in
    [
      (directory persistent "root" "root" "0711")
      (directory temporary "root" "root" "0711")
      (directory "${persistent}/root" owner group "0700")
      (directory "${persistent}/paths" owner group "0700")
      (directory "${persistent}/control" owner group "0700")
      (directory "${temporary}/root" owner group "0700")
      (directory "${temporary}/paths" owner group "0700")
      (directory "/home/${username}" owner group "0700")
    ]
    ++ lib.concatMap (root: [
      (directory "${root}/.storage" owner group "0700")
      (directory "${root}/.storage/persistent" owner group "0700")
      (directory "${root}/.storage/temporary" owner group "0700")
      (directory "${root}/.storage/control" owner group "0700")
    ]) roots;

  commonMountService = {
    restartIfChanged = false;
    after = [
      "local-fs.target"
      "systemd-tmpfiles-setup.service"
    ];
    requires = [ "systemd-tmpfiles-setup.service" ];
    unitConfig.RequiresMountsFor = [ "/persist" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
      CapabilityBoundingSet = [
        "CAP_DAC_OVERRIDE"
        "CAP_SYS_ADMIN"
      ];
      NoNewPrivileges = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
    };
  };

  replay = pkgs.writeShellApplication {
    name = "home-generation-replay";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
      pkgs.findutils
    ];
    text = builtins.readFile ./home-generation-replay.sh;
  };

  userReplayGate = pkgs.writeShellApplication {
    name = "home-storage-user-gate";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      if (( $# != 1 )); then
        echo "usage: home-storage-user-gate UID" >&2
        exit 2
      fi

      case "$1" in
        ${lib.concatMapStrings (user: ''
          ${toString user.uid})
            replay_unit=home-generation-replay-${user.username}.service
            layout_unit=home-storage-layout-${user.username}.service
            ;;
        '') eligibleUsers}
        *) exit 0 ;;
      esac

      systemctl reset-failed "$layout_unit" 2>/dev/null || true
      systemctl reset-failed "$replay_unit" 2>/dev/null || true
      exec systemctl start "$replay_unit"
    '';
  };

  rootMountServices = lib.listToAttrs (
    lib.concatMap (
      user:
      let
        inherit (user) username;
        home = "/home/${username}";
        marker = "${persistentRoot}/${username}/control/current/temporary-default";
        mkRootService =
          mode: source: condition:
          lib.nameValuePair "home-storage-root-${mode}-${username}" (
            lib.recursiveUpdate commonMountService {
              description = "Mount ${mode} home root for ${username}";
              unitConfig.ConditionPathExists = condition;
              serviceConfig = {
                ExecStart = "${pkgs.util-linux}/bin/mount --bind ${source} ${home}";
                ExecStop = "${pkgs.util-linux}/bin/umount ${home}";
              };
            }
          );
      in
      [
        (mkRootService "persistent" "${persistentRoot}/${username}/root" "!${marker}")
        (mkRootService "temporary" "${temporaryRoot}/${username}/root" marker)
      ]
    ) eligibleUsers
  );

  bucketServices = lib.listToAttrs (
    map (
      user:
      let
        inherit (user) username;
        rootUnits = [
          "home-storage-root-persistent-${username}.service"
          "home-storage-root-temporary-${username}.service"
        ];
        home = "/home/${username}/.storage";
      in
      lib.nameValuePair "home-storage-buckets-${username}" (
        lib.recursiveUpdate commonMountService {
          description = "Mount fixed home storage buckets for ${username}";
          after = commonMountService.after ++ rootUnits;
          wants = rootUnits;
          serviceConfig = {
            ExecStart = [
              "${pkgs.util-linux}/bin/mount --bind ${persistentRoot}/${username}/paths ${home}/persistent"
              "${pkgs.util-linux}/bin/mount --bind ${temporaryRoot}/${username}/paths ${home}/temporary"
              "${pkgs.util-linux}/bin/mount --bind ${persistentRoot}/${username}/control ${home}/control"
            ];
            ExecStop = [
              "${pkgs.util-linux}/bin/umount ${home}/control"
              "${pkgs.util-linux}/bin/umount ${home}/temporary"
              "${pkgs.util-linux}/bin/umount ${home}/persistent"
            ];
          };
        }
      )
    ) eligibleUsers
  );

  layoutServices = lib.listToAttrs (
    map (
      user:
      let
        inherit (user) username;
        bucketUnit = "home-storage-buckets-${username}.service";
        control = "${persistentRoot}/${username}/control";
      in
      lib.nameValuePair "home-storage-layout-${username}" {
        description = "Apply user-owned home storage layout for ${username}";
        after = [ bucketUnit ];
        requires = [ bucketUnit ];
        unitConfig.ConditionPathExists = "${control}/current/layout.conf";
        serviceConfig = {
          Type = "oneshot";
          User = username;
          Group = "users";
          UMask = "0077";
          ExecStart = "${pkgs.systemd}/bin/systemd-tmpfiles --user --create ${control}/current/layout.conf";
          TimeoutStartSec = "30s";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ReadWritePaths = [
            "/home/${username}"
            "${persistentRoot}/${username}/root"
            "${persistentRoot}/${username}/paths"
            "${persistentRoot}/${username}/control"
            "${temporaryRoot}/${username}/root"
            "${temporaryRoot}/${username}/paths"
          ];
          RestrictAddressFamilies = [ "AF_UNIX" ];
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
        };
      }
    ) eligibleUsers
  );

  replayServices = lib.listToAttrs (
    map (
      user:
      let
        inherit (user) username;
        home = "/home/${username}";
        layoutUnit = "home-storage-layout-${username}.service";
      in
      lib.nameValuePair "home-generation-replay-${username}" {
        description = "Replay the selected home generation for ${username}";
        restartIfChanged = false;
        requires = [ layoutUnit ];
        after = [ layoutUnit ];
        unitConfig.RequiresMountsFor = home;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = username;
          Group = "users";
          UMask = "0077";
          ExecStart = "${replay}/bin/home-generation-replay ${username} ${home}";
          TimeoutStartSec = "30s";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ home ];
          RestrictAddressFamilies = [ "AF_UNIX" ];
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
        };
      }
    ) eligibleUsers
  );

  bucketUnits = map (user: "home-storage-buckets-${user.username}.service") eligibleUsers;
  userManagerUnits = map (user: "user@${toString user.uid}.service") eligibleUsers;
in
{
  config = lib.mkIf enabled {
    systemd.tmpfiles.settings."10-home-storage" = lib.listToAttrs (
      [
        (directory persistentRoot "root" "root" "0711")
        (directory temporaryRoot "root" "root" "0711")
      ]
      ++ lib.concatMap userDirectories eligibleUsers
    );

    systemd.services =
      rootMountServices
      // bucketServices
      // layoutServices
      // replayServices
      // {
        home-storage-prepare = {
          description = "Prepare user-managed home storage before logins";
          wantedBy = [ "multi-user.target" ];
          restartIfChanged = false;
          wants = bucketUnits;
          after = bucketUnits;
          before = loginUnits ++ userManagerUnits;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };

        systemd-user-sessions = {
          after = [ "home-storage-prepare.service" ];
          requires = [ "home-storage-prepare.service" ];
        };

        linger-users = {
          after = [ "home-storage-prepare.service" ];
          requires = [ "home-storage-prepare.service" ];
        };

        "home-storage-user@" = {
          description = "Gate user %i on its home generation replay";
          restartIfChanged = false;
          unitConfig.StartLimitIntervalSec = 0;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${userReplayGate}/bin/home-storage-user-gate %i";
            CapabilityBoundingSet = [ ];
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            RestrictAddressFamilies = [ "AF_UNIX" ];
            LockPersonality = true;
            MemoryDenyWriteExecute = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            TimeoutStartSec = "70s";
          };
        };

        "user@" = {
          after = [
            "home-storage-prepare.service"
            "home-storage-user@%i.service"
          ];
          requires = [ "home-storage-user@%i.service" ];
        };
      };
  };
}
