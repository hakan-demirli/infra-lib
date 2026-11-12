{
  pkgs,
  self,
  inputs,
}:
let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  testCluster = {
    users.test-user.system_account = {
      username = "test-user";
      uid = 1000;
      groups = [ ];
    };
    usersOnHost.test-host = [
      {
        user = "test-user";
        unix_tier = "test-tier";
      }
    ];
    unixAccessTiers.test-tier = {
      groups = [ ];
      root_ssh = false;
      sudo.extra_rule = null;
    };
  };

  evalStorage =
    {
      tmp ? null,
      scratch ? null,
      persistentTmp ? [ ],
    }:
    (inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        host = {
          id = "test-host";
          local_storage = {
            tmp.disk = tmp;
            scratch.disk = scratch;
            persistent_tmp = persistentTmp;
          };
        };
        cluster = testCluster;
      };
      modules = [
        inputs.disko.nixosModules.disko
        (self + "/modules/system/local-storage.nix")
        {
          boot.isContainer = true;
          system.stateVersion = "26.05";
        }
      ];
    }).config;

  diskA = "/dev/disk/by-id/nvme-a";
  diskB = "/dev/disk/by-id/nvme-b";

  none = evalStorage { };
  shared = evalStorage {
    tmp = diskA;
    scratch = diskA;
    persistentTmp = [ "opencode" ];
  };
  separate = evalStorage {
    tmp = diskB;
    scratch = diskA;
    persistentTmp = [ "opencode" ];
  };
  scratchOnly = evalStorage { scratch = diskA; };
  tmpOnly = evalStorage { tmp = diskB; };

  scratchDevice = "/dev/disk/by-partlabel/disk-scratch-scratch";
  tmpDevice = "/dev/disk/by-partlabel/disk-tmp-tmp";
  storageOptions = [
    "compress=zstd:1"
    "noatime"
    "nofail"
    "x-systemd.device-timeout=10s"
  ];

  mountedFrom =
    config: mountPoint: device:
    config.fileSystems ? ${mountPoint}
    && config.fileSystems.${mountPoint}.device == device
    && lib.all (option: lib.elem option config.fileSystems.${mountPoint}.options) (
      [ "subvol=${mountPoint}" ] ++ storageOptions
    );
  reset = config: config.systemd.services.local-storage-tmp-reset;
  prepare = config: config.systemd.services.local-storage-scratch-prepare;

  checks = {
    none-adds-nothing =
      none.disko.devices.disk == { }
      && !none.fileSystems ? "/tmp"
      && !none.systemd.services ? local-storage-tmp-reset
      && !none.systemd.services ? local-storage-scratch-prepare;

    shared-uses-one-filesystem =
      lib.attrNames shared.disko.devices.disk == [ "scratch" ]
      && mountedFrom shared "/tmp" scratchDevice
      && mountedFrom shared "/scratch" scratchDevice;
    separate-uses-two-filesystems =
      lib.attrNames separate.disko.devices.disk == [
        "scratch"
        "tmp"
      ]
      && separate.disko.devices.disk.tmp.device == diskB
      && separate.disko.devices.disk.scratch.device == diskA
      && mountedFrom separate "/tmp" tmpDevice
      && mountedFrom separate "/scratch" scratchDevice;
    scratch-only-keeps-root-tmp =
      !scratchOnly.fileSystems ? "/tmp"
      && mountedFrom scratchOnly "/scratch" scratchDevice
      && !scratchOnly.systemd.services ? local-storage-tmp-reset;
    tmp-only-adds-no-scratch =
      mountedFrom tmpOnly "/tmp" tmpDevice
      && !tmpOnly.fileSystems ? "/scratch"
      && !tmpOnly.systemd.services ? local-storage-scratch-prepare;

    reset-runs-before-tmp-on-its-device =
      lib.elem "tmp.mount" (reset separate).before
      && lib.elem "dev-disk-by\\x2dpartlabel-disk\\x2dtmp\\x2dtmp.device" (reset separate).requires
      && lib.hasInfix tmpDevice (reset separate).script;
    reset-uses-shared-device = lib.hasInfix scratchDevice (reset shared).script;
    reset-skips-switch = !(reset separate).restartIfChanged;
    reset-keeps-mounted-tmp = lib.hasInfix "mountpoint -q /tmp" (reset separate).script;

    persistent-tmp-binds-from-scratch =
      separate.fileSystems."/tmp/opencode".device == "/scratch/tmp/opencode"
      && lib.elem "bind" separate.fileSystems."/tmp/opencode".options
      && lib.elem "nofail" separate.fileSystems."/tmp/opencode".options
      && lib.elem "/scratch" separate.fileSystems."/tmp/opencode".depends;
    persistent-tmp-skips-age-cleaner = lib.elem "x /tmp/opencode" separate.systemd.tmpfiles.rules;
    prepare-needs-mounted-scratch =
      lib.elem "scratch.mount" (prepare separate).requires
      && (prepare separate).unitConfig.ConditionPathIsMountPoint == "/scratch";
    prepare-runs-before-binds = lib.elem "tmp-opencode.mount" (prepare separate).before;
    prepare-creates-directories =
      lib.hasInfix "install -d -m 1777 /scratch/tmp/opencode" (prepare separate).script
      && lib.hasInfix "-o 1000 -g users /scratch/test-user" (prepare separate).script;
    scratch-is-scrubbed = lib.elem "/scratch" separate.services.btrfs.autoScrub.fileSystems;
  };

  failures = lib.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
pkgs.runCommand "local-storage-contract"
  {
    failureCount = toString (lib.length failures);
    failureNames = lib.concatStringsSep "," failures;
  }
  ''
    if [ "$failureCount" != 0 ]; then
      echo "failed local storage contracts: $failureNames" >&2
      exit 1
    fi
    touch "$out"
  ''
