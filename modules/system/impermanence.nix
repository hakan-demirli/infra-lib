{
  config,
  lib,
  pkgs,
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

  defaultSystemPaths = [
    "/var/lib/nixos"
    "/var/lib/systemd/coredump"
    "/etc/NetworkManager/system-connections"
    "/root/.cache/nix"
  ];
  defaultSystemFiles = [
    "/etc/machine-id"
    "/var/lib/systemd/credential.secret"
  ];
  systemPaths = defaultSystemPaths ++ cfg.persistentDirs ++ hostImpermanence.persisted_paths;
  systemFiles = defaultSystemFiles ++ hostImpermanence.persisted_files;
  userDirs = cfg.persistentUserDirs ++ cfg.extraPersistentUserDirs;
  userFiles = cfg.persistentUserFiles ++ cfg.extraPersistentUserFiles;

  isAbsolute = path: lib.hasPrefix "/" path;
  isRelative = path: path != "" && !isAbsolute path;
  hasTraversal = path: lib.any (part: part == "." || part == "..") (lib.splitString "/" path);
  validSystemPath = path: path != "" && isAbsolute path && !hasTraversal path;
  validUserPath = path: isRelative path && !hasTraversal path;

  grants = cluster.usersOnHost.${host.id} or [ ];
  eligibleGrants = lib.filter (
    g: (cluster.users.${g.user} or null) != null && cluster.users.${g.user}.system_account != null
  ) grants;
  eligibleUsers = map (g: cluster.users.${g.user}.system_account) eligibleGrants;

  preparePersistentHostIdentity = pkgs.writeShellApplication {
    name = "prepare-persistent-host-identity";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
      pkgs.util-linux
    ];
    text = ''
      persistent_root=/persist/system
      machine_id_path=/etc/machine-id
      credential_path=/var/lib/systemd/credential.secret
      persistent_machine_id_path="$persistent_root$machine_id_path"
      persistent_credential_path="$persistent_root$credential_path"
      temporary=

      trap '[[ -z "$temporary" ]] || rm -f "$temporary"' EXIT

      fail() {
        printf 'persistent host identity: %s\n' "$*" >&2
        exit 1
      }

      copy_atomic() {
        local source=$1
        local target=$2
        local mode=$3

        temporary="$(mktemp "$(dirname "$target")/.host-identity.XXXXXX")"
        install -o root -g root -m "$mode" "$source" "$temporary"
        mv -fT "$temporary" "$target"
        temporary=
        sync -f "$target"
      }

      read_machine_id() {
        local path=$1
        local value

        [[ -f "$path" && ! -L "$path" ]] || return 1
        value="$(<"$path")"
        [[ $value =~ ^[0-9a-f]{32}$ ]] || return 1
        printf '%s' "$value"
      }

      bind_file() {
        local live=$1
        local persistent=$2
        local mode=$3

        if [[ ! -L "$live" && -e "$live" ]] \
          && [[ "$(stat -Lc '%d:%i' "$live")" == "$(stat -Lc '%d:%i' "$persistent")" ]]; then
          return 0
        fi

        if [[ -L "$live" ]]; then
          rm -f "$live"
        elif [[ -e "$live" && ! -f "$live" ]]; then
          fail "$live is not a regular file"
        fi

        install -d -o root -g root -m 0755 "$(dirname "$live")"
        [[ -e "$live" ]] || install -o root -g root -m "$mode" /dev/null "$live"
        mount --bind "$persistent" "$live"
      }

      mountpoint -q /persist || fail "/persist is not mounted"
      install -d -o root -g root -m 0755 \
        "$(dirname "$persistent_machine_id_path")" \
        "$(dirname "$persistent_credential_path")"

      live_machine_id="$(read_machine_id "$machine_id_path" 2>/dev/null || true)"
      if ! persistent_machine_id="$(read_machine_id "$persistent_machine_id_path" 2>/dev/null)"; then
        if [[ -e "$persistent_machine_id_path" || -L "$persistent_machine_id_path" ]]; then
          [[ -f "$persistent_machine_id_path" && ! -L "$persistent_machine_id_path" ]] \
            || fail "$persistent_machine_id_path is not a regular file"
          value="$(<"$persistent_machine_id_path")"
          [[ ! -s "$persistent_machine_id_path" || $value == uninitialized ]] \
            || fail "$persistent_machine_id_path contains an invalid machine ID"
          rm -f "$persistent_machine_id_path"
        fi

        if [[ -n $live_machine_id ]]; then
          copy_atomic "$machine_id_path" "$persistent_machine_id_path" 0444
        else
          systemd-machine-id-setup --root="$persistent_root" >/dev/null
        fi

        persistent_machine_id="$(read_machine_id "$persistent_machine_id_path" 2>/dev/null)" \
          || fail "could not initialize $persistent_machine_id_path"
      fi

      chown root:root "$persistent_machine_id_path"
      chmod 0444 "$persistent_machine_id_path"
      bind_file "$machine_id_path" "$persistent_machine_id_path" 0444

      if [[ ! -s "$persistent_credential_path" ]]; then
        if [[ -e "$persistent_credential_path" || -L "$persistent_credential_path" ]]; then
          [[ -f "$persistent_credential_path" && ! -L "$persistent_credential_path" ]] \
            || fail "$persistent_credential_path is not a regular file"
          rm -f "$persistent_credential_path"
        fi

        live_credential_valid=false
        if [[ $live_machine_id == "$persistent_machine_id" \
          && -f "$credential_path" && ! -L "$credential_path" \
          && -s "$credential_path" \
          && "$(stat -Lc '%u:%g:%a:%h' "$credential_path")" == 0:0:400:1 ]]; then
          live_credential_valid=true
        fi

        if [[ $live_credential_valid == true ]]; then
          copy_atomic "$credential_path" "$persistent_credential_path" 0400
        else
          SYSTEMD_CREDENTIAL_SECRET="$persistent_credential_path" \
            systemd-creds setup
        fi
      fi

      [[ -f "$persistent_credential_path" && ! -L "$persistent_credential_path" \
        && -s "$persistent_credential_path" ]] \
        || fail "$persistent_credential_path is not a valid host credential key"
      chown root:root "$persistent_credential_path"
      chmod 0400 "$persistent_credential_path"
      bind_file "$credential_path" "$persistent_credential_path" 0400
    '';
  };
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
      default = [ ];
      description = "User-home directories persisted when home_mode is selective.";
    };
    extraPersistentUserDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    persistentUserFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    extraPersistentUserFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion =
            !hostImpermanence.enable
            || (
              host.disko != null
              && host.disko.managed
              && host.disko.layout == "btrfs-lvm"
              && hostImpermanence.rollback_backend == "btrfs"
            );
          message = "host '${host.id}': enabled impermanence requires rollback_backend=btrfs and managed disko.layout=btrfs-lvm.";
        }
        {
          assertion =
            hostImpermanence.enable
            || (
              hostImpermanence.persisted_paths == [ ]
              && hostImpermanence.persisted_files == [ ]
              && homeMode == "persist-all"
              && cfg.persistentDirs == [ ]
              && cfg.persistentUserDirs == [ ]
              && cfg.extraPersistentUserDirs == [ ]
              && cfg.persistentUserFiles == [ ]
              && cfg.extraPersistentUserFiles == [ ]
            );
          message = "host '${host.id}': persistence paths are configured while impermanence.enable=false.";
        }
        {
          assertion =
            emitUserBucket
            || (
              cfg.persistentUserDirs == [ ]
              && cfg.extraPersistentUserDirs == [ ]
              && cfg.persistentUserFiles == [ ]
              && cfg.extraPersistentUserFiles == [ ]
            );
          message = "host '${host.id}': persistent user directories/files require impermanence.home_mode=selective.";
        }
        {
          assertion = lib.all validSystemPath (systemPaths ++ systemFiles);
          message = "host '${host.id}': system persistence paths must be normalized absolute paths without '.' or '..' components.";
        }
        {
          assertion = lib.all validUserPath (userDirs ++ userFiles);
          message = "host '${host.id}': user persistence paths must be normalized relative paths without '.' or '..' components.";
        }
        {
          assertion = lib.length systemPaths == lib.length (lib.unique systemPaths);
          message = "host '${host.id}': duplicate system persistence directory declarations are forbidden.";
        }
        {
          assertion = lib.length systemFiles == lib.length (lib.unique systemFiles);
          message = "host '${host.id}': duplicate system persistence file declarations are forbidden.";
        }
        {
          assertion = lib.intersectLists systemPaths systemFiles == [ ];
          message = "host '${host.id}': a persistence path cannot be declared as both a directory and a file.";
        }
        {
          assertion = hostImpermanence.enable || config.environment.persistence == { };
          message = "host '${host.id}': environment.persistence is configured while impermanence.enable=false.";
        }
      ];
    }

    (lib.mkIf hostImpermanence.enable (
      lib.mkMerge [
        {
          fileSystems."/persist".neededForBoot = true;

          environment.persistence."/persist/system" = {
            hideMounts = true;
            directories = systemPaths;
            files = systemFiles;
          };

          system.activationScripts = {
            preparePersistentHostIdentity = {
              deps = [
                "createPersistentStorageDirs"
                "etc"
              ];
              text = "${preparePersistentHostIdentity}/bin/prepare-persistent-host-identity";
            };
            persist-files.deps = lib.mkAfter [ "preparePersistentHostIdentity" ];
          };
        }

        (lib.mkIf (emitUserBucket && eligibleUsers != [ ]) {
          environment.persistence."/persist" = {
            hideMounts = true;
            users = lib.listToAttrs (
              map (user: {
                name = user.username;
                value = {
                  directories = userDirs;
                  files = userFiles;
                };
              }) eligibleUsers
            );
          };

          systemd.tmpfiles.rules = [
            "d /persist/home/ 0777 root root -"
          ]
          ++ map (user: "d /persist/home/${user.username} 0700 ${toString user.uid} users -") eligibleUsers;
        })
      ]
    ))
  ];
}
