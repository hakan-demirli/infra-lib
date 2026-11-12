{
  config,
  lib,
  pkgs,
  utils,
  host ? null,
  cluster,
  ...
}:
let
  storage = if host == null then null else (host.local_storage or null);
  tmpDisk = if storage == null then null else storage.tmp.disk;
  scratchDisk = if storage == null then null else storage.scratch.disk;
  persistentTmp = if storage == null then [ ] else storage.persistent_tmp;
  shared = tmpDisk != null && tmpDisk == scratchDisk;

  mountOptions = [
    "compress=zstd:1"
    "noatime"
    "discard=async"
    "nofail"
    "x-systemd.device-timeout=10s"
    "x-systemd.before=local-fs.target"
  ];

  diskKey = role: if shared then "scratch" else role;

  mkDisk = key: device: roles: {
    type = "disk";
    inherit device;
    content = {
      type = "gpt";
      partitions.${key} = {
        size = "100%";
        content = {
          type = "btrfs";
          extraArgs = [
            "-f"
            "-L"
            key
          ];
          subvolumes = lib.listToAttrs (
            map (
              role:
              lib.nameValuePair "/${role}" {
                mountpoint = "/${role}";
                inherit mountOptions;
              }
            ) roles
          );
        };
      };
    };
  };

  disks =
    if shared then
      {
        scratch = mkDisk "scratch" scratchDisk [
          "tmp"
          "scratch"
        ];
      }
    else
      lib.optionalAttrs (tmpDisk != null) { tmp = mkDisk "tmp" tmpDisk [ "tmp" ]; }
      // lib.optionalAttrs (scratchDisk != null) {
        scratch = mkDisk "scratch" scratchDisk [ "scratch" ];
      };

  roleDevice =
    role:
    let
      key = diskKey role;
    in
    config.disko.devices.disk.${key}.content.partitions.${key}.device;
  tmpDevice = roleDevice "tmp";
  tmpDeviceUnit = "${utils.escapeSystemdPath tmpDevice}.device";

  users = map (entry: entry.account) (
    lib.attrValues ((import ../lib/accounts.nix { inherit lib; }).onHost cluster host.id)
  );
  persistentTmpMounts = map (name: "${utils.escapeSystemdPath "/tmp/${name}"}.mount") persistentTmp;
in
{
  config = lib.mkMerge [
    (lib.mkIf (disks != { }) { disko.devices.disk = disks; })

    (lib.mkIf (tmpDisk != null) {
      systemd.services.local-storage-tmp-reset = {
        description = "Reset the /tmp subvolume";
        wantedBy = [ "tmp.mount" ];
        before = [ "tmp.mount" ];
        requires = [ tmpDeviceUnit ];
        after = [ tmpDeviceUnit ];
        restartIfChanged = false;
        unitConfig.DefaultDependencies = "no";
        serviceConfig.Type = "oneshot";
        path = [
          pkgs.btrfs-progs
          pkgs.coreutils
          pkgs.util-linux
        ];
        script = ''
          set -euo pipefail

          if mountpoint -q /tmp; then
            exit 0
          fi

          top=$(mktemp -d /run/local-storage-top.XXXXXX)
          mount -t btrfs -o subvolid=5 ${tmpDevice} "$top"
          trap 'umount "$top"; rmdir "$top"' EXIT

          if [ -e "$top/tmp" ]; then
            btrfs subvolume delete --recursive "$top/tmp"
          fi
          btrfs subvolume create "$top/tmp"
          chmod 1777 "$top/tmp"
        '';
      };
    })

    (lib.mkIf (scratchDisk != null) {
      fileSystems = lib.listToAttrs (
        map (
          name:
          lib.nameValuePair "/tmp/${name}" {
            device = "/scratch/tmp/${name}";
            fsType = "none";
            options = [
              "bind"
              "nofail"
              "x-systemd.before=local-fs.target"
            ];
            depends = [
              "/tmp"
              "/scratch"
            ];
          }
        ) persistentTmp
      );

      systemd.services.local-storage-scratch-prepare = {
        description = "Create /scratch directories";
        wantedBy = [ "local-fs.target" ];
        requires = [ "scratch.mount" ];
        after = [ "scratch.mount" ];
        before = [ "local-fs.target" ] ++ persistentTmpMounts;
        unitConfig = {
          DefaultDependencies = "no";
          ConditionPathIsMountPoint = "/scratch";
        };
        serviceConfig.Type = "oneshot";
        path = [ pkgs.coreutils ];
        script = ''
          set -euo pipefail
          ${lib.concatMapStrings (name: ''
            install -d -m 1777 /scratch/tmp/${name}
          '') persistentTmp}
          ${lib.concatMapStrings (user: ''
            install -d -m 0700 -o ${toString user.uid} -g users /scratch/${user.username}
          '') users}
        '';
      };

      systemd.tmpfiles.rules = map (name: "x /tmp/${name}") persistentTmp;

      services.btrfs.autoScrub.fileSystems = [ "/scratch" ];
    })
  ];
}
