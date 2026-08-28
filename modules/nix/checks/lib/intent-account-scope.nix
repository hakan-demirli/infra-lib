{
  pkgs,
  self,
  ...
}:
let
  inherit (pkgs) lib;

  mkInventoryRoot =
    name: files:
    let
      writes = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          relPath: content:
          let
            slug = lib.replaceStrings [ "/" ] [ "-" ] relPath;
            src = pkgs.writeText "inv-${name}-${slug}" content;
          in
          ''
            install -D -m 0644 ${src} "$out/inventory/${relPath}"
          ''
        ) files
      );
    in
    pkgs.runCommand "inv-root-${name}" { } ''
      mkdir -p $out/inventory
      ${writes}
    '';

  loadIntent =
    root:
    let
      types = import (self + "/modules/lib/types.nix") { inherit lib; };
      inventory = import (self + "/modules/lib/inventory.nix") {
        inherit lib types;
        self = root;
      };
    in
    import (self + "/modules/lib/intent.nix") { inherit lib inventory; };

  mkUser = id: allowedHosts: uid: ''
    {
      id = "${id}";
      kind = "human";
      cohort = "staff";
      admin_scopes = [ ];
      headscale_user = "${id}";
      allowed_hosts = [ ${lib.concatMapStringsSep " " (h: ''"${h}"'') allowedHosts} ];
      system_account = {
        username = "${id}";
        uid = ${toString uid};
        shell = "bash";
      };
      keys = {
        ssh = [ ];
        age = [ ];
        u2f = [ ];
      };
    }
  '';

  mkHost = id: ''
    {
      id = "${id}";
      deployment_roles = [ "compute-role" ];
      topology_roles = [ "compute" ];
      state = "provisioned";
      location.kind = "workstation";
      ownership = {
        class = "personal";
        owner = "u-all";
      };
      hardware = {
        arch = "x86_64-linux";
        cpu_vendor = "amd";
        cpu_sockets = 1;
        cpu_cores_per_socket = 4;
        cpu_threads_per_core = 2;
        ram_mib = 16384;
      };
    }
  '';

  root = mkInventoryRoot "account-scope" {
    "users/u-all.nix" = mkUser "u-all" [ "all" ] 1000;
    "users/u-scoped.nix" = mkUser "u-scoped" [ "h-scoped" ] 1001;
    "unix-access-tiers/standard.nix" = ''
      {
        id = "standard";
        description = "test Unix access tier";
        groups = [ ];
        sudo.extra_rule = null;
        ssh.allowed = true;
        root_ssh = false;
      }
    '';
    "deployment-roles/compute-role.nix" = ''
      {
        id = "compute-role";
        description = "test deployment role";
        kind = "nixos";
        modules = [ ];
      }
    '';
    "hosts/lab/h-open.nix" = mkHost "h-open";
    "hosts/lab/h-scoped.nix" = mkHost "h-scoped";
    "clusters/c-test.nix" = ''
      {
        id = "c-test";
        ownership = {
          class = "personal";
          owner = "u-all";
        };
        members.hosts = [
          "h-open"
          "h-scoped"
        ];
        access.users = [
          {
            user = "u-all";
            unix_tier = "standard";
          }
          {
            user = "u-scoped";
            unix_tier = "standard";
          }
        ];
      }
    '';
  };

  intent = loadIntent root;

  accountPairs = lib.sort lib.lessThan (lib.unique (map (g: "${g.user}@${g.host}") intent.sshGrants));

  expectedPairs = [
    "u-all@h-open"
    "u-all@h-scoped"
    "u-scoped@h-scoped"
  ];

  checks = {
    unrestricted-user-lands-on-every-cluster-host =
      lib.elem "u-all@h-open" accountPairs && lib.elem "u-all@h-scoped" accountPairs;
    scoped-user-lands-on-its-allowed-host = lib.elem "u-scoped@h-scoped" accountPairs;
    scoped-user-is-absent-from-other-hosts = !lib.elem "u-scoped@h-open" accountPairs;
    grant-set-matches-cluster-users-materialisation = accountPairs == expectedPairs;
  };

  failures = lib.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
pkgs.runCommand "intent-account-scope"
  {
    failureCount = toString (lib.length failures);
    failureNames = lib.concatStringsSep "," failures;
    observed = lib.concatStringsSep "," accountPairs;
    expected = lib.concatStringsSep "," expectedPairs;
  }
  ''
    if [ "$failureCount" != 0 ]; then
      echo "failed intent account-scope checks: $failureNames" >&2
      echo "observed grants: $observed" >&2
      echo "expected grants: $expected" >&2
      exit 1
    fi
    touch "$out"
  ''
