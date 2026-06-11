{
  pkgs,
  self,
  inputs,
}:
let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  mkHost =
    {
      enable ? true,
      homeMode ? "persist-all",
      layout ? "btrfs-lvm",
      managed ? true,
      persistedPaths ? [ ],
      persistedFiles ? [ ],
    }:
    {
      id = "test-host";
      disko = {
        inherit layout managed;
        root_disk = "/dev/vda";
        swap_size = "1G";
      };
      impermanence = {
        inherit enable;
        rollback_backend = "btrfs";
        home_mode = homeMode;
        persisted_paths = persistedPaths;
        persisted_files = persistedFiles;
      };
    };

  testCluster = {
    users = {
      test-user-a.system_account = {
        username = "test-user-a";
        uid = 1000;
      };
      test-user-b.system_account = {
        username = "test-user-b";
        uid = 1001;
      };
    };
    usersOnHost.test-host = [
      { user = "test-user-a"; }
      { user = "test-user-b"; }
    ];
  };

  evalImpermanence =
    {
      host ? mkHost { },
      extraModule ? { },
    }:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit host;
        cluster = testCluster;
      };
      modules = [
        inputs.impermanence.nixosModules.impermanence
        (self + "/modules/system/impermanence.nix")
        {
          boot.isContainer = true;
          fileSystems."/persist" = {
            device = "none";
            fsType = "tmpfs";
          };
          system.stateVersion = "26.05";
        }
        extraModule
      ];
    };

  failedMessages =
    system:
    map (assertion: assertion.message) (
      lib.filter (assertion: !assertion.assertion) system.config.assertions
    );
  hasFailure = needle: system: lib.any (lib.hasInfix needle) (failedMessages system);

  valid = evalImpermanence { };
  wrongMode = evalImpermanence {
    extraModule.system.impermanence.extraPersistentUserDirs = [ ".config/example" ];
  };
  disabledPayload = evalImpermanence {
    host = mkHost { enable = false; };
    extraModule.environment.persistence."/persist/system".directories = [ "/var/lib/example" ];
  };
  malformedPath = evalImpermanence {
    host = mkHost { persistedPaths = [ "var/lib/example" ]; };
  };
  duplicateDefaultFile = evalImpermanence {
    host = mkHost { persistedFiles = [ "/var/lib/systemd/credential.secret" ]; };
  };
  duplicateDefaultDirectory = evalImpermanence {
    host = mkHost { persistedPaths = [ "/var/lib/nixos" ]; };
  };
  selective = evalImpermanence {
    host = mkHost { homeMode = "selective"; };
    extraModule.system.impermanence.persistentUserDirs = [ "Documents" ];
  };

  evalLayout =
    homeMode:
    (lib.evalModules {
      specialArgs.host = mkHost { inherit homeMode; };
      modules = [
        {
          options.disko.devices = lib.mkOption {
            type = lib.types.anything;
            default = { };
          };
        }
        (self + "/modules/system/disko/btrfs-lvm.nix")
      ];
    }).config.disko.devices;

  hasHome = devices: devices.lvm_vg.root_vg.lvs.root.content.subvolumes ? "/home";
  persistedSystemFiles = map (
    file: file.filePath
  ) valid.config.environment.persistence."/persist/system".files;

  checks = {
    valid-has-no-contract-failure = !lib.any (lib.hasPrefix "host 'test-host':") (failedMessages valid);
    wrong-mode-fails = hasFailure "require impermanence.home_mode=selective" wrongMode;
    disabled-persistence-fails = hasFailure "environment.persistence is configured" disabledPayload;
    malformed-system-path-fails = hasFailure "normalized absolute paths" malformedPath;
    duplicate-default-file-fails = hasFailure "duplicate system persistence file" duplicateDefaultFile;
    duplicate-default-directory-fails = hasFailure "duplicate system persistence directory" duplicateDefaultDirectory;
    host-identity-is-persistent =
      lib.elem "/etc/machine-id" persistedSystemFiles
      && lib.elem "/var/lib/systemd/credential.secret" persistedSystemFiles;
    host-identity-precedes-file-persistence = lib.elem "preparePersistentHostIdentity" valid.config.system.activationScripts.persist-files.deps;
    selective-emits-all-users =
      lib.attrNames selective.config.environment.persistence."/persist".users == [
        "test-user-a"
        "test-user-b"
      ];
    persist-all-has-separate-home = hasHome (evalLayout "persist-all");
    selective-has-ephemeral-home = !hasHome (evalLayout "selective");
    ephemeral-has-ephemeral-home = !hasHome (evalLayout "ephemeral");
    user-managed-has-ephemeral-home = !hasHome (evalLayout "user-managed");
  };

  failures = lib.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
pkgs.runCommand "impermanence-contract"
  {
    failureCount = toString (lib.length failures);
    failureNames = lib.concatStringsSep "," failures;
    hostIdentityPreparer = valid.config.system.activationScripts.preparePersistentHostIdentity.text;
  }
  ''
    if [ "$failureCount" != 0 ]; then
      echo "failed impermanence contracts: $failureNames" >&2
      exit 1
    fi
    test -x "$hostIdentityPreparer"
    grep -q 'systemd-creds setup' "$hostIdentityPreparer"
    touch "$out"
  ''
