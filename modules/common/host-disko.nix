{
  lib,
  host ? null,
  ...
}:
let
  implementedLayouts = [
    "zfs-single"
    "ext4-single"
    "btrfs-single"
    "btrfs-lvm"
  ];

  d = if host == null then null else (host.disko or null);
  c = if host == null then null else (host.ceph or null);

  cephDisks = if c == null then [ ] else c.osd_disks;
  hasCeph = cephDisks != [ ];

  dataEntries = lib.filter (e: e.role == "data") cephDisks;
  lvEntries = lib.filter (e: e.role == "block.db" || e.role == "block.wal") cephDisks;

  diskoKeyOfData = entry: "ceph-osd-${entry.name}";

  reservedDataDisks = lib.listToAttrs (
    map (entry: {
      name = diskoKeyOfData entry;
      value = {
        type = "disk";
        device = entry.path;
        content = null;
      };
    }) dataEntries
  );

  lvByVg =
    let
      grouped = lib.foldl' (
        acc: e:
        acc
        // {
          ${e.vg_name} = (acc.${e.vg_name} or [ ]) ++ [ e ];
        }
      ) { } lvEntries;
    in
    grouped;

  vgPath = vgEntries: (lib.head vgEntries).path;

  diskoKeyOfVg = vgName: "ceph-vg-${vgName}";

  sharedVgDisks = lib.mapAttrs' (
    vgName: vgEntries:
    lib.nameValuePair (diskoKeyOfVg vgName) {
      type = "disk";
      device = vgPath vgEntries;
      content = {
        type = "gpt";
        partitions.pv = {
          size = "100%";
          content = {
            type = "lvm_pv";
            vg = vgName;
          };
        };
      };
    }
  ) lvByVg;

  vgAttrs = lib.mapAttrs (_vgName: vgEntries: {
    type = "lvm_vg";
    lvs = lib.listToAttrs (
      map (entry: {
        inherit (entry) name;
        value = {
          size = "${toString entry.size_gib}G";
          content = null;
        };
      }) vgEntries
    );
  }) lvByVg;

  cephManagementMismatch = hasCeph && (d == null || !d.managed);

  rootDiskPath = if d == null then null else d.root_disk;
  cephPaths = map (e: e.path) cephDisks;

  rootCollision = rootDiskPath != null && lib.elem rootDiskPath cephPaths;

  dataPaths = map (e: e.path) dataEntries;
  lvPaths = map (e: e.path) lvEntries;
  dataDuplicates =
    let
      counts = lib.foldl' (
        acc: p:
        acc
        // {
          ${p} = (acc.${p} or 0) + 1;
        }
      ) { } dataPaths;
    in
    lib.attrNames (lib.filterAttrs (_: n: n > 1) counts);
  dataPathsDuplicated = dataDuplicates != [ ];

  crossBucketCollisions = lib.filter (p: lib.elem p dataPaths) (lib.unique lvPaths);
  crossBucketCollision = crossBucketCollisions != [ ];

  duplicateOsdNames =
    let
      names = map (e: e.name) cephDisks;
      counts = lib.foldl' (
        acc: n:
        acc
        // {
          ${n} = (acc.${n} or 0) + 1;
        }
      ) { } names;
    in
    lib.attrNames (lib.filterAttrs (_: cnt: cnt > 1) counts);
  duplicateNamesPresent = duplicateOsdNames != [ ];

  missingVgName = lib.filter (
    e: (e.role == "block.db" || e.role == "block.wal") && e.vg_name == ""
  ) cephDisks;
  missingSize = lib.filter (
    e: (e.role == "block.db" || e.role == "block.wal") && e.size_gib == null
  ) cephDisks;

  vgPathConflicts =
    let
      paths = lib.mapAttrs (_: entries: lib.unique (map (e: e.path) entries)) lvByVg;
      bad = lib.filterAttrs (_: ps: lib.length ps > 1) paths;
    in
    bad;
  vgPathConflictPresent = vgPathConflicts != { };

  emptyOsdName = lib.any (e: e.name == "") cephDisks;
in
{
  imports = [
    ../system/disko/zfs-single.nix
    ../system/disko/ext4-single.nix
    ../system/disko/btrfs-single.nix
    ../system/disko/btrfs-lvm.nix
  ];

  config = {
    disko.devices.disk = lib.mkIf (
      hasCeph
      && d != null
      && d.managed
      && !rootCollision
      && !crossBucketCollision
      && !dataPathsDuplicated
      && !duplicateNamesPresent
      && !emptyOsdName
      && missingVgName == [ ]
      && missingSize == [ ]
      && !vgPathConflictPresent
    ) (reservedDataDisks // sharedVgDisks);

    disko.devices.lvm_vg = lib.mkIf (
      hasCeph
      && d != null
      && d.managed
      && lvEntries != [ ]
      && !rootCollision
      && !crossBucketCollision
      && !dataPathsDuplicated
      && !duplicateNamesPresent
      && !emptyOsdName
      && missingVgName == [ ]
      && missingSize == [ ]
      && !vgPathConflictPresent
    ) vgAttrs;

    assertions =
      lib.optional (d != null && d.managed) {
        assertion = lib.elem d.layout implementedLayouts;
        message =
          "host.disko.layout '${d.layout}' is in the schema enum but no "
          + "layout module exists yet (host '${host.id}'). Implemented "
          + "today: "
          + lib.concatStringsSep ", " implementedLayouts
          + ". Add modules/system/disko/${d.layout}.nix to enable.";
      }
      ++ lib.optional cephManagementMismatch {
        assertion = false;
        message =
          "host '${host.id}' declares host.ceph.osd_disks but host.disko.managed = false "
          + "(or host.disko is unset). OSD reservation only fires when the host is disko-managed; "
          + "set [disko].managed = true after verifying with `disko --mode mount --dry-run`.";
      }
      ++ lib.optional rootCollision {
        assertion = false;
        message =
          "host '${host.id}' lists host.disko.root_disk '${rootDiskPath}' "
          + "in host.ceph.osd_disks. Wiping the OS disk as an OSD would brick the host. "
          + "Pick a different disk for the OSD or change root_disk.";
      }
      ++ lib.optional crossBucketCollision {
        assertion = false;
        message =
          "host '${host.id}' has the same path in both role=\"data\" and role=\"block.{db,wal}\" "
          + "entries: "
          + lib.concatStringsSep ", " crossBucketCollisions
          + ". A device is either a whole-OSD data disk OR a shared WAL/DB carrier, not both.";
      }
      ++ lib.optional dataPathsDuplicated {
        assertion = false;
        message =
          "host '${host.id}' lists the same path in multiple role=\"data\" entries: "
          + lib.concatStringsSep ", " dataDuplicates
          + ". Each data OSD must have its own device. "
          + "(block.db/block.wal entries legitimately share a device via vg_name; only role=data is checked here.)";
      }
      ++ lib.optional duplicateNamesPresent {
        assertion = false;
        message =
          "host '${host.id}' has duplicate names in host.ceph.osd_disks: "
          + lib.concatStringsSep ", " duplicateOsdNames
          + ". Each name becomes a disko key and must be unique.";
      }
      ++ lib.optional emptyOsdName {
        assertion = false;
        message =
          "host '${host.id}' has a host.ceph.osd_disks entry with empty name. "
          + "Every entry needs a stable identifier (becomes the disko key disk.<name> or lvs.<name>).";
      }
      ++ lib.optional (missingVgName != [ ]) {
        assertion = false;
        message =
          "host '${host.id}' has block.db/block.wal entries with empty vg_name: "
          + lib.concatStringsSep ", " (map (e: e.name) missingVgName)
          + ". The block.* roles require vg_name to know which LVM VG to carve from.";
      }
      ++ lib.optional (missingSize != [ ]) {
        assertion = false;
        message =
          "host '${host.id}' has block.db/block.wal entries with null size_gib: "
          + lib.concatStringsSep ", " (map (e: e.name) missingSize)
          + ". The block.* roles require an explicit LV size in GiB.";
      }
      ++ lib.optional vgPathConflictPresent {
        assertion = false;
        message =
          "host '${host.id}' has block.* entries claiming the same vg_name but different paths: "
          + lib.concatStringsSep "; " (
            lib.mapAttrsToList (vg: ps: "${vg} -> {${lib.concatStringsSep ", " ps}}") vgPathConflicts
          )
          + ". All LVs in one VG live on one underlying disk; pick one path per vg_name or split into separate VGs.";
      };
  };
}
