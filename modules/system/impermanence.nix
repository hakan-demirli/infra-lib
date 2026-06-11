{
  config,
  lib,
  host,
  cluster,
  ...
}:
let
  cfg = config.system.impermanence;
  hostImpermanence =
    host.impermanence or {
      enable = false;
      persisted_paths = [ ];
      persisted_files = [ ];
      home_mode = "persist-all";
    };
  homeMode = hostImpermanence.home_mode or "persist-all";
  emitUserBucket = homeMode == "selective";

  grants = cluster.usersOnHost.${host.id} or [ ];
  primaryGrant = lib.findFirst (
    g: (cluster.users.${g.user} or null) != null && cluster.users.${g.user}.system_account != null
  ) null grants;
  primaryUser = if primaryGrant == null then null else cluster.users.${primaryGrant.user};
  primaryUsername = if primaryUser == null then "root" else primaryUser.system_account.username;
  primaryUid = if primaryUser == null then 0 else primaryUser.system_account.uid;
in
{
  options.system.impermanence = {
    persistentDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra system-side directories to persist (e.g. /var/lib/libvirt, /persist/xilinx).";
    };

    persistentUserDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "Desktop"
        "Documents"
        "Downloads"
        "Videos"
        ".cache"
        ".local/share"
        ".local/bin/private"
        ".local/state/opencode"
        ".local/state/raider"
        ".config/opencode"
        ".antigravity"
        ".claude"
        ".config/Antigravity"
        ".gemini"
      ];
      description = ''
        User-home dirs persisted via bind-mount from /persist/home/<u>/X
        over /home/<u>/X. ONLY READ when host.impermanence.home_mode =
        "selective"; ignored otherwise.
      '';
    };
    extraPersistentUserDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    persistentUserFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ".claude.json" ];
    };
    extraPersistentUserFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
  };

  config = lib.mkIf hostImpermanence.enable (
    lib.mkMerge [
      {
        fileSystems."/persist".neededForBoot = true;

        environment.persistence."/persist/system" = {
          hideMounts = true;
          directories = [
            "/var/lib/nixos"
            "/var/lib/systemd/coredump"
            "/etc/NetworkManager/system-connections"
            "/root/.cache/nix"
          ]
          ++ cfg.persistentDirs
          ++ hostImpermanence.persisted_paths;
          files = hostImpermanence.persisted_files;
        };
      }

      (lib.mkIf (emitUserBucket && primaryUser != null) {
        environment.persistence."/persist" = {
          hideMounts = true;
          users.${primaryUsername} = {
            directories = cfg.persistentUserDirs ++ cfg.extraPersistentUserDirs;
            files = cfg.persistentUserFiles ++ cfg.extraPersistentUserFiles;
          };
        };

        systemd.tmpfiles.rules = [
          "d /persist/home/ 0777 root root -"
          "d /persist/home/${primaryUsername} 0700 ${toString primaryUid} users -"
        ];
      })
    ]
  );
}
