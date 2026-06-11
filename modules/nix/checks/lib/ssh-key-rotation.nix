{ pkgs, self }:
let
  inherit (pkgs) lib;

  fakeKeyA = "ssh-ed25519 AAAA-key-A-shouldNotPersist test-A@rotation";
  fakeKeyB = "ssh-ed25519 AAAA-key-B-shouldAppear   test-B@rotation";

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
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
      };
      warnings = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      environment = lib.mkOption {
        type = lib.types.attrs;
        default = { };
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

  mkUserSet = sshKey: {
    u1 = {
      id = "u1";
      kind = "human";
      cohort = "admin";
      allowed_hosts = [ "all" ];
      xrdp_access = false;
      expires = null;
      archived = false;
      archived_at = null;
      headscale_user = null;
      labels = { };
      keys = {
        ssh = [ sshKey ];
        age = [ ];
        u2f = [ ];
      };
      system_account = {
        username = "emre";
        uid = 1000;
        shell = "bash";
        groups = [ ];
        hashed_password_key = null;
      };
    };
  };

  mkClusterWithKey = sshKey: {
    users = mkUserSet sshKey;
    usersOnHost.host-rot = [
      {
        user = "u1";
        tier = "admin";
        via_team = null;
        via_team_role = null;
        can_submit_to = [ ];
      }
    ];
    accessTiers = {
      admin = {
        ssh = {
          allowed = true;
        };
        sudo = "NOPASSWD:ALL";
        extra_groups = [ "wheel" ];
        slurm_qos = null;
      };
    };
  };

  testHost = {
    id = "host-rot";
    ssh_trust = { };
    boot = {
      kernel_package = null;
    };
  };

  evalUsers =
    sshKey:
    (lib.evalModules {
      modules = [
        {
          _module.args = {
            inherit pkgs;
            host = testHost;
            cluster = mkClusterWithKey sshKey;
          };
        }
        ambient
        ambientFreeform
        (self + "/modules/common/cluster-users.nix")
      ];
    }).config;

  cfgA = evalUsers fakeKeyA;
  cfgB = evalUsers fakeKeyB;

  authKeysA = cfgA.users.users.emre.openssh.authorizedKeys.keys or [ ];
  authKeysB = cfgB.users.users.emre.openssh.authorizedKeys.keys or [ ];
in
pkgs.runCommand "ssh-key-rotation"
  {
    keyABeforeRotation = toString (lib.elem fakeKeyA authKeysA);
    keyBAfterRotation = toString (lib.elem fakeKeyB authKeysB);
    keyAAbsentAfterRotation = toString (!(lib.elem fakeKeyA authKeysB));
    keyBAbsentBeforeRotation = toString (!(lib.elem fakeKeyB authKeysA));
    countA = toString (builtins.length authKeysA);
    countB = toString (builtins.length authKeysB);
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }
    pass() { echo "PASS: $*"; }

    [ "$keyABeforeRotation" = "1" ] \
      || fail "before rotation: keyA should be in authorized_keys (count=$countA)"
    pass "before rotation: keyA present"

    [ "$keyBAfterRotation" = "1" ] \
      || fail "after rotation: keyB should appear in authorized_keys (count=$countB)"
    pass "after rotation: keyB present"

    [ "$keyAAbsentAfterRotation" = "1" ] \
      || fail "after rotation: keyA STILL in authorized_keys -- rotation didn't drop it"
    pass "after rotation: keyA correctly removed"

    [ "$keyBAbsentBeforeRotation" = "1" ] \
      || fail "before rotation: keyB present but shouldn't be"
    pass "sanity: keyB not present before rotation"

    echo "SSH-KEY-ROTATION INVARIANTS VERIFIED"
    echo "    keyA: present before, absent after"
    echo "    keyB: absent before, present after"
    touch $out
  ''
