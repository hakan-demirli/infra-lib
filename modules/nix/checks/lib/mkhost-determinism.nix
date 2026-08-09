{ pkgs, self }:
let
  inherit (pkgs) lib;

  types = import (self + "/modules/lib/types.nix") { inherit lib; };

  syntheticInventory = pkgs.runCommand "inv-determinism" { } ''
    mkdir -p $out/inventory/{hosts/personal,users,deployment-roles,sites,racks,networks,teams,unix-access-tiers,clusters,switches,topologies,projects}

    cat > $out/inventory/users/inventory-user.nix <<'EOF'
    {
      id = "inventory-user";
      kind = "human";
      cohort = "staff";
      admin_scopes = [ "fleet" ];
      allowed_hosts = [ "all" ];
      system_account = {
        username = "inventory-user";
        uid = 1000;
        shell = "bash";
      };
      keys = {
        ssh = [ "ssh-ed25519 AAAA-fake-key inventory-user@determinism" ];
        age = [ ];
        u2f = [ ];
      };
    }
    EOF

    cat > $out/inventory/sites/test-site.nix <<'EOF'
    {
      id = "test-site";
      location = "lab";
      power_budget_kw = 100;
      cooling = "air";
    }
    EOF

    cat > $out/inventory/deployment-roles/compute-role.nix <<'EOF'
    {
      id = "compute-role";
      description = "synthetic deployment role";
      kind = "nixos";
      modules = [ ];
    }
    EOF

    cat > $out/inventory/hosts/personal/test-host.nix <<'EOF'
    {
      id = "test-host";
      deployment_roles = [ "compute-role" ];
      topology_roles = [ "compute" ];
      state = "provisioned";
      location.kind = "workstation";
      ownership = {
        class = "personal";
        owner = "inventory-user";
        operator = "inventory-user";
        custodian = "inventory-user";
      };
      hardware = {
        arch = "x86_64-linux";
        cpu_vendor = "amd";
        cpu_sockets = 1;
        cpu_cores_per_socket = 4;
        cpu_threads_per_core = 2;
        ram_mib = 16384;
      };
      labels = { };
    }
    EOF
  '';

  invA = import (self + "/modules/lib/inventory.nix") {
    inherit lib types;
    self = syntheticInventory;
  };
  invB = import (self + "/modules/lib/inventory.nix") {
    inherit lib types;
    self = syntheticInventory;
  };

  jsonA = builtins.toJSON {
    inherit (invA) hosts;
    inherit (invA) users;
    inherit (invA) deploymentRoles;
  };
  jsonB = builtins.toJSON {
    inherit (invB) hosts;
    inherit (invB) users;
    inherit (invB) deploymentRoles;
  };

  hashA = builtins.hashString "sha256" jsonA;
  hashB = builtins.hashString "sha256" jsonB;
in
pkgs.runCommand "mkhost-determinism"
  {
    sameJson = toString (jsonA == jsonB);
    sameHash = toString (hashA == hashB);
    inherit hashA;
    inherit hashB;
    sizeA = toString (builtins.stringLength jsonA);
    sizeB = toString (builtins.stringLength jsonB);
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }
    pass() { echo "PASS: $*"; }

    [ "$sameJson" = "1" ] \
      || fail "inventory load #1 != inventory load #2 (sizeA=$sizeA sizeB=$sizeB)"
    pass "two identical inventory loads produce byte-identical JSON ($sizeA bytes)"

    [ "$sameHash" = "1" ] \
      || fail "sha256 differs: A=$hashA B=$hashB"
    pass "sha256 matches across both loads: $hashA"

    echo "MKHOST DETERMINISM VERIFIED"
    touch $out
  ''
