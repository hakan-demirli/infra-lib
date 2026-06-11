{
  pkgs,
  self,
  ...
}:
let
  inherit (pkgs) lib;

  mkZfs =
    args: (import (self + "/modules/system/disko/zfs-single/_devices.nix")) ({ inherit lib; } // args);
  mkExt4 =
    args: (import (self + "/modules/system/disko/ext4-single/_devices.nix")) ({ inherit lib; } // args);
  mkBtrfs =
    args:
    (import (self + "/modules/system/disko/btrfs-single/_devices.nix")) ({ inherit lib; } // args);
  mkBtrfsLvm =
    args: (import (self + "/modules/system/disko/btrfs-lvm/_devices.nix")) ({ inherit lib; } // args);

  zfs = mkZfs {
    device = "/dev/disk/by-id/test";
    swapSize = "32G";
  };
  zfsNoSwap = mkZfs {
    device = "/dev/disk/by-id/test";
    swapSize = "0G";
  };
  ext4 = mkExt4 {
    device = "/dev/vda";
    swapSize = "1G";
  };
  btrfs = mkBtrfs {
    device = "/dev/sda";
    swapSize = "8G";
  };
  btrfsLvm = mkBtrfsLvm {
    device = "/dev/sdb";
    swapSize = "16G";
    additionalDisks = [ ];
  };

  dispatcherEval =
    host:
    (lib.evalModules {
      modules = [
        { _module.args = { inherit host; }; }
        {
          options = {
            disko.devices = lib.mkOption {
              type = lib.types.attrsOf (lib.types.attrsOf lib.types.attrs);
              default = { };
            };
            networking.hostId = lib.mkOption {
              type = lib.types.str;
              default = "";
            };
            boot.supportedFilesystems = lib.mkOption {
              type = lib.types.anything;
              default = { };
            };
            boot.zfs.forceImportRoot = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
            assertions = lib.mkOption {
              type = lib.types.listOf lib.types.attrs;
              default = [ ];
            };
          };
        }
        (self + "/modules/common/host-disko.nix")
      ];
    }).config;

  hostManagedOff = {
    id = "h-off";
    disko = {
      root_disk = "/dev/vda";
      layout = "ext4-single";
      swap_size = "1G";
      managed = false;
    };
  };
  hostUnimplementedLayout = {
    id = "h-unimpl";
    disko = {
      root_disk = "/dev/vda";
      layout = "xfs-md-raid10";
      swap_size = "1G";
      managed = true;
    };
  };
  hostManagedZfs = {
    id = "h-zfs";
    disko = {
      root_disk = "/dev/disk/by-id/test";
      layout = "zfs-single";
      swap_size = "8G";
      managed = true;
    };
  };

  mkData =
    {
      name,
      path,
      class ? "hdd",
      size_gib ? null,
    }:
    {
      inherit
        name
        path
        class
        size_gib
        ;
      role = "data";
      vg_name = "";
      reserve_only = true;
    };

  mkBlockDb =
    {
      name,
      path,
      vg_name,
      size_gib,
      class ? "nvme",
    }:
    {
      inherit
        name
        path
        class
        size_gib
        vg_name
        ;
      role = "block.db";
      reserve_only = true;
    };

  mkBlockWal =
    {
      name,
      path,
      vg_name,
      size_gib,
      class ? "nvme",
    }:
    {
      inherit
        name
        path
        class
        size_gib
        vg_name
        ;
      role = "block.wal";
      reserve_only = true;
    };

  hostStorageCeph = {
    id = "h-storage";
    disko = {
      root_disk = "/dev/disk/by-id/nvme-system";
      layout = "ext4-single";
      swap_size = "0G";
      managed = true;
    };
    ceph.osd_disks = [
      (mkData {
        name = "osd-0";
        path = "/dev/disk/by-id/ata-WDC-A";
        size_gib = 8000;
      })
      (mkData {
        name = "osd-1";
        path = "/dev/disk/by-id/ata-WDC-B";
        size_gib = 8000;
      })
      (mkData {
        name = "osd-2";
        path = "/dev/disk/by-id/ata-WDC-C";
        size_gib = 8000;
      })
    ];
  };

  hostSharedNvme = {
    id = "h-shared-nvme";
    disko = {
      root_disk = "/dev/disk/by-id/nvme-system";
      layout = "ext4-single";
      swap_size = "0G";
      managed = true;
    };
    ceph.osd_disks = [
      (mkData {
        name = "osd-0";
        path = "/dev/disk/by-id/ata-WDC-A";
        size_gib = 8000;
      })
      (mkData {
        name = "osd-1";
        path = "/dev/disk/by-id/ata-WDC-B";
        size_gib = 8000;
      })
      (mkBlockDb {
        name = "db-osd-0";
        path = "/dev/disk/by-id/nvme-fast";
        vg_name = "ceph-fast";
        size_gib = 30;
      })
      (mkBlockWal {
        name = "wal-osd-0";
        path = "/dev/disk/by-id/nvme-fast";
        vg_name = "ceph-fast";
        size_gib = 2;
      })
      (mkBlockDb {
        name = "db-osd-1";
        path = "/dev/disk/by-id/nvme-fast";
        vg_name = "ceph-fast";
        size_gib = 30;
      })
      (mkBlockWal {
        name = "wal-osd-1";
        path = "/dev/disk/by-id/nvme-fast";
        vg_name = "ceph-fast";
        size_gib = 2;
      })
    ];
  };

  hostCephRootCollision = {
    id = "h-collide";
    disko = {
      root_disk = "/dev/disk/by-id/nvme-system";
      layout = "ext4-single";
      swap_size = "0G";
      managed = true;
    };
    ceph.osd_disks = [
      (mkData {
        name = "osd-0";
        path = "/dev/disk/by-id/nvme-system";
        class = "nvme";
      })
    ];
  };

  hostCephDuplicate = {
    id = "h-dup";
    disko = {
      root_disk = "/dev/disk/by-id/nvme-system";
      layout = "ext4-single";
      swap_size = "0G";
      managed = true;
    };
    ceph.osd_disks = [
      (mkData {
        name = "osd-0";
        path = "/dev/disk/by-id/ata-WDC-A";
      })
      (mkData {
        name = "osd-1";
        path = "/dev/disk/by-id/ata-WDC-A";
      })
    ];
  };

  hostCephCrossBucket = {
    id = "h-cross";
    disko = {
      root_disk = "/dev/disk/by-id/nvme-system";
      layout = "ext4-single";
      swap_size = "0G";
      managed = true;
    };
    ceph.osd_disks = [
      (mkData {
        name = "osd-0";
        path = "/dev/disk/by-id/nvme-fast";
        class = "nvme";
      })
      (mkBlockDb {
        name = "db-osd-0";
        path = "/dev/disk/by-id/nvme-fast";
        vg_name = "ceph-fast";
        size_gib = 30;
      })
    ];
  };

  hostMissingVgName = {
    id = "h-no-vg";
    disko = {
      root_disk = "/dev/disk/by-id/nvme-system";
      layout = "ext4-single";
      swap_size = "0G";
      managed = true;
    };
    ceph.osd_disks = [
      (mkBlockDb {
        name = "db-osd-0";
        path = "/dev/disk/by-id/nvme-fast";
        vg_name = "";
        size_gib = 30;
      })
    ];
  };

  hostMissingLvSize = {
    id = "h-no-size";
    disko = {
      root_disk = "/dev/disk/by-id/nvme-system";
      layout = "ext4-single";
      swap_size = "0G";
      managed = true;
    };
    ceph.osd_disks = [
      {
        name = "wal-osd-0";
        path = "/dev/disk/by-id/nvme-fast";
        role = "block.wal";
        class = "nvme";
        size_gib = null;
        vg_name = "ceph-fast";
        reserve_only = true;
      }
    ];
  };

  hostVgPathConflict = {
    id = "h-vg-split";
    disko = {
      root_disk = "/dev/disk/by-id/nvme-system";
      layout = "ext4-single";
      swap_size = "0G";
      managed = true;
    };
    ceph.osd_disks = [
      (mkBlockDb {
        name = "db-osd-0";
        path = "/dev/disk/by-id/nvme-fast-1";
        vg_name = "ceph-fast";
        size_gib = 30;
      })
      (mkBlockDb {
        name = "db-osd-1";
        path = "/dev/disk/by-id/nvme-fast-2";
        vg_name = "ceph-fast";
        size_gib = 30;
      })
    ];
  };

  hostCephManagementMismatch = {
    id = "h-mismatch";
    disko = {
      root_disk = "/dev/disk/by-id/nvme-system";
      layout = "ext4-single";
      swap_size = "0G";
      managed = false;
    };
    ceph.osd_disks = [
      (mkData {
        name = "osd-0";
        path = "/dev/disk/by-id/ata-WDC-A";
      })
    ];
  };

  scnOff = dispatcherEval hostManagedOff;
  scnUnimpl = dispatcherEval hostUnimplementedLayout;
  scnZfs = dispatcherEval hostManagedZfs;
  scnStorageCeph = dispatcherEval hostStorageCeph;
  scnSharedNvme = dispatcherEval hostSharedNvme;
  scnRootCollision = dispatcherEval hostCephRootCollision;
  scnCephDup = dispatcherEval hostCephDuplicate;
  scnCrossBucket = dispatcherEval hostCephCrossBucket;
  scnMissingVg = dispatcherEval hostMissingVgName;
  scnMissingSize = dispatcherEval hostMissingLvSize;
  scnVgConflict = dispatcherEval hostVgPathConflict;
  scnMismatch = dispatcherEval hostCephManagementMismatch;

  factsJson = builtins.toJSON {
    zfs = {
      partitions = builtins.attrNames zfs.disk.main.content.partitions;
      poolMode = zfs.zpool.rpool.mode;
      poolDatasets = builtins.attrNames zfs.zpool.rpool.datasets;
      rootMount = zfs.zpool.rpool.datasets."local/root".mountpoint;
      swapResume = zfs.disk.main.content.partitions.swap.content.resumeDevice;
      reservedReservation = zfs.zpool.rpool.datasets."reserved".options.refreservation;
    };
    zfsNoSwap = {
      partitions = builtins.attrNames zfsNoSwap.disk.main.content.partitions;
    };
    ext4 = {
      partitions = builtins.attrNames ext4.disk.main.content.partitions;
      rootFormat = ext4.disk.main.content.partitions.root.content.format;
      rootMount = ext4.disk.main.content.partitions.root.content.mountpoint;
      swapResume = ext4.disk.main.content.partitions.swap.content.resumeDevice;
    };
    btrfs = {
      partitions = builtins.attrNames btrfs.disk.main.content.partitions;
      subvols = builtins.attrNames btrfs.disk.main.content.partitions.root.content.subvolumes;
      rootMount = btrfs.disk.main.content.partitions.root.content.subvolumes."/root".mountpoint;
    };
    btrfsLvm = {
      partitions = builtins.attrNames btrfsLvm.disk.main.content.partitions;
      vgs = builtins.attrNames btrfsLvm.lvm_vg;
      rootLvType = btrfsLvm.lvm_vg.root_vg.lvs.root.content.type;
    };
  };

  scnOffEmpty = scnOff.disko.devices == { };
  scnOffNoAsserts = (lib.filter (a: !a.assertion) scnOff.assertions) == [ ];

  scnUnimplFailed =
    let
      failed = lib.filter (a: !a.assertion) scnUnimpl.assertions;
    in
    lib.length failed == 1 && lib.hasInfix "no layout module exists yet" (lib.head failed).message;

  scnZfsHasPool = scnZfs.disko.devices ? zpool && scnZfs.disko.devices.zpool ? rpool;
  scnZfsHostId = scnZfs.networking.hostId;

  storageDiskKeys = lib.attrNames scnStorageCeph.disko.devices.disk;
  storageOsdEntries = lib.filter (k: lib.hasPrefix "ceph-osd-" k) storageDiskKeys;
  storageOsdContentsAllNull = lib.all (
    k: scnStorageCeph.disko.devices.disk.${k}.content == null
  ) storageOsdEntries;
  storageOsdPaths = map (k: scnStorageCeph.disko.devices.disk.${k}.device) storageOsdEntries;
  storageHasRootDisk = scnStorageCeph.disko.devices.disk ? main;
  storageRootHasContent = scnStorageCeph.disko.devices.disk.main.content != null;
  storageNoAsserts = (lib.filter (a: !a.assertion) scnStorageCeph.assertions) == [ ];

  nvmeDisks = scnSharedNvme.disko.devices.disk;
  nvmeOsdDataKeys = lib.filter (k: lib.hasPrefix "ceph-osd-" k) (lib.attrNames nvmeDisks);
  nvmeHasVgCarrier = nvmeDisks ? "ceph-vg-ceph-fast";
  nvmeVgCarrierPath = nvmeDisks."ceph-vg-ceph-fast".device or null;
  nvmeVgCarrierContent = nvmeDisks."ceph-vg-ceph-fast".content or null;
  nvmeVg = scnSharedNvme.disko.devices.lvm_vg.ceph-fast or null;
  nvmeLvNames = if nvmeVg == null then [ ] else lib.attrNames nvmeVg.lvs;
  nvmeLvContentsAllNull = nvmeVg != null && lib.all (n: nvmeVg.lvs.${n}.content == null) nvmeLvNames;
  nvmeDbSize = nvmeVg.lvs."db-osd-0".size or "";
  nvmeWalSize = nvmeVg.lvs."wal-osd-0".size or "";
  nvmeNoAsserts = (lib.filter (a: !a.assertion) scnSharedNvme.assertions) == [ ];

  hasFailingAssertWith =
    scn: needle:
    let
      failed = lib.filter (a: !a.assertion) scn.assertions;
    in
    lib.length failed >= 1 && lib.any (a: lib.hasInfix needle a.message) failed;

  scnCollisionFailed = hasFailingAssertWith scnRootCollision "Wiping the OS disk";
  scnDupFailed = hasFailingAssertWith scnCephDup "multiple role=\"data\"";
  scnCrossFailed = hasFailingAssertWith scnCrossBucket "data\" and role=\"block";
  scnMissingVgFailed = hasFailingAssertWith scnMissingVg "empty vg_name";
  scnMissingSizeFailed = hasFailingAssertWith scnMissingSize "null size_gib";
  scnVgConflictFailed = hasFailingAssertWith scnVgConflict "same vg_name but different paths";
  scnMismatchFailed = hasFailingAssertWith scnMismatch "managed = false";
in
pkgs.runCommand "disko-wiring"
  {
    inherit factsJson;
    scnOffEmpty = if scnOffEmpty then "yes" else "no";
    scnOffNoAsserts = if scnOffNoAsserts then "yes" else "no";
    scnUnimplFailed = if scnUnimplFailed then "yes" else "no";
    scnZfsHasPool = if scnZfsHasPool then "yes" else "no";
    inherit scnZfsHostId;
    storageOsdCount = toString (lib.length storageOsdEntries);
    storageOsdContentsAllNull = if storageOsdContentsAllNull then "yes" else "no";
    storageOsdPathsJson = builtins.toJSON storageOsdPaths;
    storageHasRootDisk = if storageHasRootDisk then "yes" else "no";
    storageRootHasContent = if storageRootHasContent then "yes" else "no";
    storageNoAsserts = if storageNoAsserts then "yes" else "no";
    nvmeOsdDataCount = toString (lib.length nvmeOsdDataKeys);
    nvmeHasVgCarrier = if nvmeHasVgCarrier then "yes" else "no";
    nvmeVgCarrierPath = if nvmeVgCarrierPath == null then "" else nvmeVgCarrierPath;
    nvmeVgCarrierContentType = if nvmeVgCarrierContent == null then "" else nvmeVgCarrierContent.type;
    nvmeLvNamesJson = builtins.toJSON nvmeLvNames;
    nvmeLvContentsAllNull = if nvmeLvContentsAllNull then "yes" else "no";
    inherit nvmeDbSize nvmeWalSize;
    nvmeNoAsserts = if nvmeNoAsserts then "yes" else "no";
    scnCollisionFailed = if scnCollisionFailed then "yes" else "no";
    scnDupFailed = if scnDupFailed then "yes" else "no";
    scnCrossFailed = if scnCrossFailed then "yes" else "no";
    scnMissingVgFailed = if scnMissingVgFailed then "yes" else "no";
    scnMissingSizeFailed = if scnMissingSizeFailed then "yes" else "no";
    scnVgConflictFailed = if scnVgConflictFailed then "yes" else "no";
    scnMismatchFailed = if scnMismatchFailed then "yes" else "no";
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }
    pass() { echo "PASS: $*"; }

    echo "facts: $factsJson"

    j() { echo "$factsJson" | ${pkgs.jq}/bin/jq -er "$@"; }

    test "$(j '.zfs.partitions | length')" = "3"   || fail "zfs: partition count"
    j '.zfs.partitions | index("ESP")'   >/dev/null || fail "zfs: ESP missing"
    j '.zfs.partitions | index("swap")'  >/dev/null || fail "zfs: swap missing"
    j '.zfs.partitions | index("zfs")'   >/dev/null || fail "zfs: zfs partition missing"
    test "$(j '.zfs.swapResume')" = "true"          || fail "zfs: swap resumeDevice"
    j '.zfs.poolDatasets | index("local/root")'   >/dev/null || fail "zfs: local/root dataset missing"
    j '.zfs.poolDatasets | index("local/nix")'    >/dev/null || fail "zfs: local/nix dataset missing"
    j '.zfs.poolDatasets | index("safe/persist")' >/dev/null || fail "zfs: safe/persist dataset missing"
    j '.zfs.poolDatasets | index("reserved")'     >/dev/null || fail "zfs: reserved dataset missing"
    test "$(j '.zfs.rootMount')" = "/"              || fail "zfs: root mountpoint"
    test "$(j '.zfs.reservedReservation')" = "1G"   || fail "zfs: reserved refreservation 1G"
    pass "zfs-single: 3 partitions, swap-resume, 8 datasets, root=/, 1G reservation"

    j '.zfsNoSwap.partitions | length == 2' >/dev/null \
      || fail "zfs-noswap: should have 2 partitions (ESP + zfs), got $(j '.zfsNoSwap.partitions')"
    j '.zfsNoSwap.partitions | index("swap") == null' >/dev/null \
      || fail "zfs-noswap: swap partition should be absent"
    pass "zfs-single: omits swap partition when swap_size=\"0G\""

    test "$(j '.ext4.partitions | length')" = "3"  || fail "ext4: partition count"
    test "$(j '.ext4.rootFormat')" = "ext4"        || fail "ext4: root format"
    test "$(j '.ext4.rootMount')"  = "/"           || fail "ext4: root mount"
    test "$(j '.ext4.swapResume')" = "false"       || fail "ext4: swap should NOT be resumeDevice"
    pass "ext4-single: ESP + swap (no resume) + ext4 /"

    j '.btrfs.subvols | index("/root")'        >/dev/null || fail "btrfs: /root subvol missing"
    j '.btrfs.subvols | index("/root-blank")'  >/dev/null || fail "btrfs: /root-blank (impermanence) missing"
    j '.btrfs.subvols | index("/nix")'         >/dev/null || fail "btrfs: /nix subvol missing"
    j '.btrfs.subvols | index("/persist")'     >/dev/null || fail "btrfs: /persist subvol missing"
    test "$(j '.btrfs.rootMount')" = "/"       || fail "btrfs: /root subvol must mount /"
    pass "btrfs-single: 4 subvols including /root-blank for impermanence"

    j '.btrfsLvm.vgs | index("root_vg")' >/dev/null || fail "btrfs-lvm: root_vg missing"
    test "$(j '.btrfsLvm.rootLvType')" = "btrfs"    || fail "btrfs-lvm: root LV content type"
    pass "btrfs-lvm: legacy layout still produces root_vg with btrfs LV"

    test "$scnOffEmpty" = "yes" \
      || fail "dispatcher: managed=false should produce empty disko.devices, got scnOffEmpty=$scnOffEmpty"
    test "$scnOffNoAsserts" = "yes" \
      || fail "dispatcher: managed=false should produce zero failing assertions, got scnOffNoAsserts=$scnOffNoAsserts"
    pass "dispatcher: host.disko.managed=false -> empty devices, no asserts (default-safe)"

    test "$scnUnimplFailed" = "yes" \
      || fail "dispatcher: requesting an unimplemented layout (xfs-md-raid10) should emit a failing assertion with 'no layout module exists yet' in the message"
    pass "dispatcher: unimplemented layout -> failing assertion at eval (operator sees the message)"

    test "$scnZfsHasPool" = "yes" \
      || fail "dispatcher: managed=true + zfs-single should populate disko.devices.zpool.rpool"
    echo "$scnZfsHostId" | ${pkgs.gnugrep}/bin/grep -qE '^[0-9a-f]{8}$' \
      || fail "dispatcher: zfs-single should derive 8-char hex networking.hostId, got '$scnZfsHostId'"
    pass "dispatcher: managed=true + zfs-single -> rpool materialised + hostId derived ($scnZfsHostId)"

    test "$storageHasRootDisk" = "yes" \
      || fail "storage-ceph: root disk (disk.main) missing -- ext4-single layout didn't fire"
    test "$storageRootHasContent" = "yes" \
      || fail "storage-ceph: root disk.main should have content (ext4 etc.), got null"
    test "$storageOsdCount" = "3" \
      || fail "storage-ceph: expected 3 reserved ceph-osd-* disks, got $storageOsdCount"
    test "$storageOsdContentsAllNull" = "yes" \
      || fail "storage-ceph: every ceph-osd-* disk must have content = null (raw/reserved). Got otherwise."
    echo "$storageOsdPathsJson" | ${pkgs.jq}/bin/jq -er 'index("/dev/disk/by-id/ata-WDC-A")' >/dev/null \
      || fail "storage-ceph: osd-0 device path missing from emitted disks"
    echo "$storageOsdPathsJson" | ${pkgs.jq}/bin/jq -er 'index("/dev/disk/by-id/ata-WDC-B")' >/dev/null \
      || fail "storage-ceph: osd-1 device path missing"
    echo "$storageOsdPathsJson" | ${pkgs.jq}/bin/jq -er 'index("/dev/disk/by-id/ata-WDC-C")' >/dev/null \
      || fail "storage-ceph: osd-2 device path missing"
    test "$storageNoAsserts" = "yes" \
      || fail "storage-ceph: should have zero failing assertions on a well-formed host"
    pass "storage-ceph: 3 OSD disks reserved (content=null), root disk formatted, no asserts"

    test "$nvmeOsdDataCount" = "2" \
      || fail "shared-nvme: expected 2 ceph-osd-* data disks, got $nvmeOsdDataCount"
    test "$nvmeHasVgCarrier" = "yes" \
      || fail "shared-nvme: expected disko.devices.disk.\"ceph-vg-ceph-fast\" backing the shared NVMe, missing"
    test "$nvmeVgCarrierPath" = "/dev/disk/by-id/nvme-fast" \
      || fail "shared-nvme: VG carrier device path wrong, got '$nvmeVgCarrierPath'"
    test "$nvmeVgCarrierContentType" = "gpt" \
      || fail "shared-nvme: VG carrier should be a GPT-partitioned disk (then PV), got '$nvmeVgCarrierContentType'"
    echo "$nvmeLvNamesJson" | ${pkgs.jq}/bin/jq -er 'length == 4' >/dev/null \
      || fail "shared-nvme: expected 4 LVs (db-osd-{0,1}, wal-osd-{0,1}), got $nvmeLvNamesJson"
    for lv in db-osd-0 db-osd-1 wal-osd-0 wal-osd-1; do
      echo "$nvmeLvNamesJson" | ${pkgs.jq}/bin/jq -er "index(\"$lv\")" >/dev/null \
        || fail "shared-nvme: LV '$lv' missing from lvm_vg.ceph-fast.lvs"
    done
    test "$nvmeLvContentsAllNull" = "yes" \
      || fail "shared-nvme: every LV must have content=null (raw, for BlueStore to consume)"
    test "$nvmeDbSize" = "30G" \
      || fail "shared-nvme: db-osd-0 LV size should be '30G', got '$nvmeDbSize'"
    test "$nvmeWalSize" = "2G" \
      || fail "shared-nvme: wal-osd-0 LV size should be '2G', got '$nvmeWalSize'"
    test "$nvmeNoAsserts" = "yes" \
      || fail "shared-nvme: should have zero failing assertions on a well-formed host"
    pass "shared-nvme: 2 data OSDs + ceph-vg carrier + 4 raw LVs (db/wal x2) on one shared NVMe"

    test "$scnCollisionFailed" = "yes" \
      || fail "ceph collision: a host listing root_disk in osd_disks must trigger a failing assertion (would brick the host otherwise)"
    pass "ceph collision: root_disk == osd_disks[*].path -> failing assertion (safeguard fires)"

    test "$scnDupFailed" = "yes" \
      || fail "ceph duplicate-data: two role=data entries sharing a path must trigger a failing assertion"
    pass "ceph duplicate-data: same path twice in role=data entries -> failing assertion"

    test "$scnCrossFailed" = "yes" \
      || fail "ceph cross-bucket: a path appearing as both role=data and role=block.* must trigger a failing assertion"
    pass "ceph cross-bucket: same path in data + block.* -> failing assertion"

    test "$scnMissingVgFailed" = "yes" \
      || fail "ceph missing-vg: block.db entry without vg_name must trigger a failing assertion"
    pass "ceph missing-vg: block.* entry with empty vg_name -> failing assertion"

    test "$scnMissingSizeFailed" = "yes" \
      || fail "ceph missing-size: block.wal entry without size_gib must trigger a failing assertion"
    pass "ceph missing-size: block.* entry with null size_gib -> failing assertion"

    test "$scnVgConflictFailed" = "yes" \
      || fail "ceph vg-conflict: two block.* entries on same vg_name but different paths must trigger a failing assertion"
    pass "ceph vg-conflict: same vg_name across different paths -> failing assertion"

    test "$scnMismatchFailed" = "yes" \
      || fail "ceph management mismatch: host with osd_disks but managed=false must trigger a failing assertion (would be silently ignored otherwise)"
    pass "ceph management mismatch: osd_disks + managed=false -> failing assertion (no silent drop)"

    echo "" > $out
    echo "all disko-wiring assertions passed" >> $out
  ''
