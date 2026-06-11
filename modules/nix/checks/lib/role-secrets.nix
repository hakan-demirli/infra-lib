{
  pkgs,
  self,
  ...
}:
let
  inherit (pkgs) lib;

  bucketsRoot = pkgs.runCommand "test-buckets" { } ''
    mkdir -p $out/secrets/roles
    echo 'munge_key: "FAKE ENCRYPTED PAYLOAD"' > $out/secrets/roles/with-bucket.yml
  '';

  optionStubs = {
    options.sops.secrets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
    };
    options.assertions = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
      default = [ ];
    };
  };

  mkRoleSecretsConfig =
    {
      host,
      cluster,
      selfPath,
    }:
    (lib.evalModules {
      modules = [
        {
          _module.args = {
            inherit host cluster;
            self = selfPath;
          };
        }
        optionStubs
        (self + "/modules/common/role-secrets.nix")
      ];
    }).config;

  scn1Host = {
    id = "host-1";
    roles = [ "with-bucket" ];
  };
  scn1Cluster = {
    roles."with-bucket" = {
      secret_paths.munge-key = {
        source_key = "munge_key";
        path = "/etc/munge/munge.key";
        owner = "munge";
        group = "munge";
        mode = "0400";
      };
    };
  };
  scn1Result = mkRoleSecretsConfig {
    host = scn1Host;
    cluster = scn1Cluster;
    selfPath = bucketsRoot;
  };

  scn2Host = {
    id = "host-2";
    roles = [ "with-secrets-no-bucket" ];
  };
  scn2Cluster = {
    roles."with-secrets-no-bucket" = {
      secret_paths.something = {
        source_key = "k";
        path = "/etc/something";
        owner = "root";
        group = "root";
        mode = "0400";
      };
    };
  };
  scn2Result = mkRoleSecretsConfig {
    host = scn2Host;
    cluster = scn2Cluster;
    selfPath = bucketsRoot;
  };

  scn3Host = {
    id = "host-3";
    roles = [ "no-secrets" ];
  };
  scn3Cluster = {
    roles."no-secrets" = {
    };
  };
  scn3Result = mkRoleSecretsConfig {
    host = scn3Host;
    cluster = scn3Cluster;
    selfPath = bucketsRoot;
  };

  collisionRoot = pkgs.runCommand "collision-buckets" { } ''
    mkdir -p $out/secrets/roles
    echo 'k: "x"' > $out/secrets/roles/role-a.yml
    echo 'k: "y"' > $out/secrets/roles/role-b.yml
  '';

  scn4Host = {
    id = "host-4";
    roles = [
      "role-a"
      "role-b"
    ];
  };
  scn4Cluster = {
    roles = {
      role-a.secret_paths.dup = {
        source_key = "k";
        path = "/etc/dup-a";
        owner = "root";
        group = "root";
        mode = "0400";
      };
      role-b.secret_paths.dup = {
        source_key = "k";
        path = "/etc/dup-b";
        owner = "root";
        group = "root";
        mode = "0400";
      };
    };
  };
  scn4Try =
    let
      cfg = mkRoleSecretsConfig {
        host = scn4Host;
        cluster = scn4Cluster;
        selfPath = collisionRoot;
      };
    in
    builtins.tryEval (builtins.deepSeq cfg.assertions cfg.assertions);

  clusterBucketsRoot = pkgs.runCommand "test-cluster-buckets" { } ''
    mkdir -p $out/secrets/clusters
    echo 'munge_key: "FAKE CLUSTER PAYLOAD"' > $out/secrets/clusters/lab-fpga.yml
  '';

  scn5Host = {
    id = "h5";
    roles = [ "noop" ];
  };
  scn5Cluster = {
    roles."noop" = { };
    clusters."lab-fpga" = {
      secret_paths.munge-key = {
        source_key = "munge_key";
        path = "/etc/munge/munge.key";
        owner = "munge";
        group = "munge";
        mode = "0400";
      };
    };
    hostToCluster.h5 = "lab-fpga";
  };
  scn5Result = mkRoleSecretsConfig {
    host = scn5Host;
    cluster = scn5Cluster;
    selfPath = clusterBucketsRoot;
  };

  clusterRoleCollideRoot = pkgs.runCommand "test-cluster-role-collide" { } ''
    mkdir -p $out/secrets/roles $out/secrets/clusters
    echo 'k: "x"' > $out/secrets/roles/some-role.yml
    echo 'k: "y"' > $out/secrets/clusters/some-cluster.yml
  '';

  scn6Host = {
    id = "h6";
    roles = [ "some-role" ];
  };
  scn6Cluster = {
    roles."some-role".secret_paths.dup = {
      source_key = "k";
      path = "/etc/role-dup";
      owner = "root";
      group = "root";
      mode = "0400";
    };
    clusters."some-cluster".secret_paths.dup = {
      source_key = "k";
      path = "/etc/cluster-dup";
      owner = "root";
      group = "root";
      mode = "0400";
    };
    hostToCluster.h6 = "some-cluster";
  };
  scn6Try =
    let
      cfg = mkRoleSecretsConfig {
        host = scn6Host;
        cluster = scn6Cluster;
        selfPath = clusterRoleCollideRoot;
      };
    in
    builtins.tryEval (builtins.deepSeq cfg.assertions cfg.assertions);

  scn1Json = builtins.toJSON scn1Result.sops.secrets;
  scn2Json = builtins.toJSON scn2Result.sops.secrets;
  scn3Json = builtins.toJSON scn3Result.sops.secrets;

  recordAsserts =
    tryResult:
    if !tryResult.success then
      [
        {
          assertion = false;
          message = "tryEval threw on collision (acceptable)";
        }
      ]
    else
      tryResult.value;
  scn4Json = builtins.toJSON (recordAsserts scn4Try);
  scn5Json = builtins.toJSON scn5Result.sops.secrets;
  scn6Json = builtins.toJSON (recordAsserts scn6Try);

in
pkgs.runCommand "role-secrets"
  {
    inherit
      scn1Json
      scn2Json
      scn3Json
      scn4Json
      scn5Json
      scn6Json
      ;
    bucketsRoot = "${bucketsRoot}";
    clusterBucketsRoot = "${clusterBucketsRoot}";
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }
    pass() { echo "PASS: $*"; }

    echo "scn1: $scn1Json"

    echo "$scn1Json" | grep -q '"munge-key"' \
      || fail "scn1: sops.secrets.munge-key entry missing"
    echo "$scn1Json" | grep -q '"path":"/etc/munge/munge.key"' \
      || fail "scn1: path field not wired"
    echo "$scn1Json" | grep -q '"owner":"munge"' \
      || fail "scn1: owner field not wired"
    echo "$scn1Json" | grep -q '"group":"munge"' \
      || fail "scn1: group field not wired"
    echo "$scn1Json" | grep -q '"mode":"0400"' \
      || fail "scn1: mode field not wired"
    echo "$scn1Json" | grep -q '"key":"munge_key"' \
      || fail "scn1: source_key not mapped to .key"
    echo "$scn1Json" | grep -q "$bucketsRoot/secrets/roles/with-bucket.yml" \
      || fail "scn1: sopsFile does not point at the bucket fixture (got: $scn1Json)"
    pass "scn1: role with secret_paths + bucket -> entry materialised, all fields correct"

    echo "scn2: $scn2Json"
    [ "$scn2Json" = "{}" ] \
      || fail "scn2: role with secret_paths but no bucket should emit no entries; got: $scn2Json"
    pass "scn2: role with secret_paths but missing bucket -> silent skip"

    echo "scn3: $scn3Json"
    [ "$scn3Json" = "{}" ] \
      || fail "scn3: role without secret_paths should emit no entries; got: $scn3Json"
    pass "scn3: role without secret_paths -> empty sops.secrets"

    echo "scn4: $scn4Json"
    echo "$scn4Json" | grep -q '"assertion":false' \
      || fail "scn4: expected a failing assertion for the duplicate-name collision"
    echo "$scn4Json" | grep -qE 'role:role-a.*role:role-b|role:role-b.*role:role-a' \
      || fail "scn4: collision message should mention both role-a and role-b with role: prefix; got: $scn4Json"
    pass "scn4: name collision across roles fires a failing assertion"

    echo "scn5: $scn5Json"
    echo "$scn5Json" | grep -q '"munge-key"' \
      || fail "scn5: cluster.secret_paths.munge-key not materialised"
    echo "$scn5Json" | grep -q '"path":"/etc/munge/munge.key"' \
      || fail "scn5: cluster munge-key path not wired"
    echo "$scn5Json" | grep -q "$clusterBucketsRoot/secrets/clusters/lab-fpga.yml" \
      || fail "scn5: cluster sopsFile does not point at secrets/clusters/<cid>.yml; got: $scn5Json"
    pass "scn5: cluster.secret_paths -> entry from secrets/clusters/<cid>.yml"

    echo "scn6: $scn6Json"
    echo "$scn6Json" | grep -q '"assertion":false' \
      || fail "scn6: expected a failing assertion for the role-vs-cluster name collision"
    echo "$scn6Json" | grep -qE 'role:some-role.*cluster:some-cluster|cluster:some-cluster.*role:some-role' \
      || fail "scn6: collision message should mention BOTH role:some-role AND cluster:some-cluster; got: $scn6Json"
    pass "scn6: role-vs-cluster name collision fires a failing assertion naming both kinds"

    echo "" > $out
    echo "all role-secrets assertions passed" >> $out
  ''
