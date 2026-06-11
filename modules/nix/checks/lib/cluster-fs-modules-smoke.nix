{ pkgs, self }:
let
  inherit (pkgs) lib;

  testCluster = {
    clusters.uni-hpc = {
      id = "uni-hpc";
      cluster_fs = {
        backend = "cephfs";
        mountpoint = "/mnt/shared";
        cephfs = {
          fsid = "00000000-1111-2222-3333-444444444444";
          fs_name = "cephfs";
          client_name = "client.admin";
          monitors = [
            "node-a:6789"
            "node-b:6789"
            "node-c:6789"
          ];
          mds_active = "node-a";
          mds_standby = "node-b";
          nfs = null;
        };
        nfs = null;
      };
      cephfs = null;
      nfs = null;
    };

    hosts = {
      node-a = {
        id = "node-a";
        cluster = "uni-hpc";
        ownership.owner = "u1";
        ceph.osd_disks = [
          {
            name = "node-a-osd";
            role = "data";
            path = "/dev/sdb";
          }
        ];
      };
      node-client = {
        id = "node-client";
        cluster = "uni-hpc";
        ownership.owner = "u1";
        ceph.osd_disks = [ ];
      };
    };

    users.u1 = {
      system_account = {
        username = "u1";
        uid = 1001;
      };
      keys.ssh = [ "ssh-ed25519 AAAA..." ];
    };
  };

  nfsCluster = {
    clusters.simple-lab = {
      id = "simple-lab";
      cluster_fs = {
        backend = "nfs";
        mountpoint = "/mnt/shared";
        cephfs = null;
        nfs = {
          server = "fileserver";
          export = "/exports/shared";
        };
      };
    };
    hosts.client = {
      id = "client";
      cluster = "simple-lab";
      ownership.owner = "u1";
    };
  };

  ambientOptions = {
    options = {
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
      };
      services = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
      systemd = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
      networking = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
      environment = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
      boot = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
      fileSystems = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
    };
  };

  tryModule =
    modPath: extraArgs:
    let
      raw = lib.evalModules {
        modules = [
          {
            _module.args = {
              inherit lib pkgs;
            }
            // extraArgs;
          }
          ambientOptions
          modPath
        ];
      };
    in
    builtins.tryEval (builtins.length raw.config.assertions);

  monAtNodeA = tryModule (self + "/modules/services/ceph-mon.nix") {
    host = testCluster.hosts.node-a;
    cluster = testCluster;
  };
  osdAtNodeA = tryModule (self + "/modules/services/ceph-osd.nix") {
    host = testCluster.hosts.node-a;
    cluster = testCluster;
  };
  mgrAtNodeA = tryModule (self + "/modules/services/ceph-mgr.nix") {
    host = testCluster.hosts.node-a;
    cluster = testCluster;
  };
  mdsAtNodeA = tryModule (self + "/modules/services/ceph-mds.nix") {
    host = testCluster.hosts.node-a;
    cluster = testCluster;
  };
  fsAtClient = tryModule (self + "/modules/services/cluster-fs.nix") {
    host = testCluster.hosts.node-client;
    cluster = testCluster;
  };
  fsNfs = tryModule (self + "/modules/services/cluster-fs.nix") {
    host = nfsCluster.hosts.client;
    cluster = nfsCluster;
  };

  monAtUnlisted = tryModule (self + "/modules/services/ceph-mon.nix") {
    host = {
      id = "stranger";
      cluster = "uni-hpc";
      ownership.owner = "u1";
    };
    cluster = testCluster;
  };
in
pkgs.runCommand "cluster-fs-modules-smoke"
  {
    monA = toString monAtNodeA.success;
    osdA = toString osdAtNodeA.success;
    mgrA = toString mgrAtNodeA.success;
    mdsA = toString mdsAtNodeA.success;
    fsCephfsClient = toString fsAtClient.success;
    fsNfsClient = toString fsNfs.success;
    monUnlistedSuccess = toString monAtUnlisted.success;
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }
    pass() { echo "PASS: $*"; }

    [ "$monA" = "1" ] || fail "ceph-mon on a listed monitor should eval"
    pass "ceph-mon on node-a evals"

    [ "$osdA" = "1" ] || fail "ceph-osd should eval when host has osd_disks"
    pass "ceph-osd on node-a evals"

    [ "$mgrA" = "1" ] || fail "ceph-mgr should eval"
    pass "ceph-mgr on node-a evals"

    [ "$mdsA" = "1" ] || fail "ceph-mds should eval"
    pass "ceph-mds on node-a evals"

    [ "$fsCephfsClient" = "1" ] || fail "cluster-fs dispatch should eval for cephfs backend"
    pass "cluster-fs dispatcher (cephfs) on client evals"

    [ "$fsNfsClient" = "1" ] || fail "cluster-fs dispatch should eval for nfs backend"
    pass "cluster-fs dispatcher (nfs) on client evals"

    [ "$monUnlistedSuccess" = "1" ] || fail "ceph-mon on unlisted host: eval should still pass (assertion fires at activate)"
    pass "ceph-mon assertion gates without breaking eval"

    echo "CLUSTER-FS MODULES SMOKE VERIFIED"
    touch $out
  ''
