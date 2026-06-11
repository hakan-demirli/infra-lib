{ pkgs, self }:
let
  inherit (pkgs) lib;

  keyAlice = "ssh-ed25519 AAAA-alice alice@offboarding-test";
  keyBob = "ssh-ed25519 AAAA-bob   bob@offboarding-test";

  ambient = {
    options = {
      services = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
      programs = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
      security = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
      sops = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
      systemd = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
      environment = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
      };
      warnings = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
    };
  };

  ambientFreeform = {
    options.users.users = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          freeformType = lib.types.attrs;
        }
      );
    };
  };

  mkUser =
    {
      uname,
      uid,
      sshKey,
      archived,
      isRoot ? true,
    }:
    {
      id = uname;
      kind = "human";
      cohort = "admin";
      is_root_anywhere = isRoot;
      allowed_hosts = [ "all" ];
      xrdp_access = false;
      expires = null;
      inherit archived;
      archived_at = if archived then "2026-01-01" else null;
      headscale_user = null;
      labels = { };
      keys = {
        ssh = [ sshKey ];
        age = [ ];
        u2f = [ ];
      };
      system_account = {
        username = uname;
        inherit uid;
        shell = "bash";
        groups = [ ];
        home = "/home/${uname}";
        hashed_password_key = null;
      };
    };

  mkCluster = bobArchived: {
    users = {
      alice = mkUser {
        uname = "alice";
        uid = 1001;
        sshKey = keyAlice;
        archived = false;
      };
      bob = mkUser {
        uname = "bob";
        uid = 1002;
        sshKey = keyBob;
        archived = bobArchived;
      };
    };
    usersOnHost.off-host = [
      {
        user = "alice";
        tier = "admin";
        via_team = null;
        via_team_role = null;
        can_submit_to = [ ];
      }
      {
        user = "bob";
        tier = "admin";
        via_team = null;
        via_team_role = null;
        can_submit_to = [ ];
      }
    ];
    accessTiers.admin = {
      ssh = {
        allowed = true;
      };
      sudo = "NOPASSWD:ALL";
      extra_groups = [ "wheel" ];
      slurm_qos = null;
    };
  };

  testHost = {
    id = "off-host";
    ssh_trust = { };
    boot = {
      kernel_package = null;
    };
  };

  evalCfg =
    bobArchived:
    (lib.evalModules {
      modules = [
        {
          _module.args = {
            inherit pkgs;
            host = testHost;
            cluster = mkCluster bobArchived;
          };
        }
        ambient
        ambientFreeform
        (self + "/modules/common/cluster-users.nix")
      ];
    }).config;

  active = evalCfg false;
  archived = evalCfg true;

  activeUsers = builtins.attrNames (active.users.users or { });
  archivedUsers = builtins.attrNames (archived.users.users or { });
  archivedRootKeys = archived.users.users.root.openssh.authorizedKeys.keys or [ ];
  activeRootKeys = active.users.users.root.openssh.authorizedKeys.keys or [ ];
in
pkgs.runCommand "user-offboarding"
  {
    aliceInBaseline = toString (lib.elem "alice" activeUsers);
    bobInBaseline = toString (lib.elem "bob" activeUsers);
    aliceStillThereAfterBobArchived = toString (lib.elem "alice" archivedUsers);
    bobDroppedAfterArchive = toString (!(lib.elem "bob" archivedUsers));
    bobKeyInBaselineRoot = toString (lib.elem keyBob activeRootKeys);
    bobKeyDroppedFromRootAfterArchive = toString (!(lib.elem keyBob archivedRootKeys));
    activeUserCount = toString (builtins.length activeUsers);
    archivedUserCount = toString (builtins.length archivedUsers);
    archivedRootKeyList = lib.concatStringsSep " " archivedRootKeys;
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }
    pass() { echo "PASS: $*"; }

    [ "$aliceInBaseline" = "1" ] || fail "baseline: alice missing"
    [ "$bobInBaseline" = "1" ] || fail "baseline: bob missing"
    [ "$bobKeyInBaselineRoot" = "1" ] || fail "baseline: bob's key should be in root authorized_keys"
    pass "baseline: alice + bob both present; bob's key in root"

    [ "$aliceStillThereAfterBobArchived" = "1" ] \
      || fail "after archive: alice was incorrectly removed"
    pass "after archive: alice's account intact"

    [ "$bobDroppedAfterArchive" = "1" ] \
      || fail "after archive: bob's account is STILL in users.users (offboarding broken)"
    pass "after archive: bob's account removed"

    [ "$bobKeyDroppedFromRootAfterArchive" = "1" ] \
      || fail "after archive: bob's SSH key STILL in root authorized_keys: $archivedRootKeyList"
    pass "after archive: bob's SSH key removed from root authorized_keys"

    echo "USER OFFBOARDING INVARIANTS VERIFIED"
    echo "    pre:  $activeUserCount users present"
    echo "    post: $archivedUserCount users present"
    touch $out
  ''
