{ pkgs, self }:
let
  inherit (pkgs) lib;

  activeUserKey = "ssh-ed25519 AAAA-active-user active-user@offboarding-test";
  departingUserKey = "ssh-ed25519 AAAA-departing-user departing-user@offboarding-test";

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
    }:
    {
      id = uname;
      kind = "human";
      cohort = "staff";
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
        hashed_password_key = null;
      };
    };

  mkCluster = departingUserArchived: {
    users = {
      active-user = mkUser {
        uname = "active-user";
        uid = 1001;
        sshKey = activeUserKey;
        archived = false;
      };
      departing-user = mkUser {
        uname = "departing-user";
        uid = 1002;
        sshKey = departingUserKey;
        archived = departingUserArchived;
      };
    };
    usersOnHost.off-host = [
      {
        user = "active-user";
        unix_tier = "admin";
        via_team = null;
        via_team_role = null;
        can_submit_to = [ ];
      }
      {
        user = "departing-user";
        unix_tier = "admin";
        via_team = null;
        via_team_role = null;
        can_submit_to = [ ];
      }
    ];
    unixAccessTiers.admin = {
      ssh = {
        allowed = true;
      };
      sudo.extra_rule = "NOPASSWD:ALL";
      groups = [ "wheel" ];
      root_ssh = true;
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
    departingUserArchived:
    (lib.evalModules {
      modules = [
        {
          _module.args = {
            inherit pkgs;
            host = testHost;
            cluster = mkCluster departingUserArchived;
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
    activeUserInBaseline = toString (lib.elem "active-user" activeUsers);
    departingUserInBaseline = toString (lib.elem "departing-user" activeUsers);
    activeUserStillPresent = toString (lib.elem "active-user" archivedUsers);
    departingUserDroppedAfterArchive = toString (!(lib.elem "departing-user" archivedUsers));
    departingUserKeyInBaselineRoot = toString (lib.elem departingUserKey activeRootKeys);
    departingUserKeyDroppedFromRoot = toString (!(lib.elem departingUserKey archivedRootKeys));
    activeUserCount = toString (builtins.length activeUsers);
    archivedUserCount = toString (builtins.length archivedUsers);
    archivedRootKeyList = lib.concatStringsSep " " archivedRootKeys;
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }
    pass() { echo "PASS: $*"; }

    [ "$activeUserInBaseline" = "1" ] || fail "baseline: active-user missing"
    [ "$departingUserInBaseline" = "1" ] || fail "baseline: departing-user missing"
    [ "$departingUserKeyInBaselineRoot" = "1" ] \
      || fail "baseline: departing-user's key should be in root authorized_keys"
    pass "baseline: active-user + departing-user both present; departing-user's key in root"

    [ "$activeUserStillPresent" = "1" ] \
      || fail "after archive: active-user was incorrectly removed"
    pass "after archive: active-user's account intact"

    [ "$departingUserDroppedAfterArchive" = "1" ] \
      || fail "after archive: departing-user's account is STILL in users.users (offboarding broken)"
    pass "after archive: departing-user's account removed"

    [ "$departingUserKeyDroppedFromRoot" = "1" ] \
      || fail "after archive: departing-user's SSH key STILL in root authorized_keys: $archivedRootKeyList"
    pass "after archive: departing-user's SSH key removed from root authorized_keys"

    echo "USER OFFBOARDING INVARIANTS VERIFIED"
    echo "    pre:  $activeUserCount users present"
    echo "    post: $archivedUserCount users present"
    touch $out
  ''
