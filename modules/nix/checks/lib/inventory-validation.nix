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

  tryLoad =
    root:
    let
      types = import (self + "/modules/lib/types.nix") { inherit lib; };
      inv = import (self + "/modules/lib/inventory.nix") {
        inherit lib types;
        self = root;
      };
    in
    builtins.tryEval (builtins.deepSeq inv.hosts inv.hosts);

  validUser = id: ''
    {
      id = "${id}";
      kind = "human";
      cohort = "admin";
      headscale_user = "${id}";
      allowed_hosts = [ "all" ];
      system_account = {
        username = "${id}";
        uid = 1000;
        shell = "bash";
      };
      keys = {
        ssh = [ ];
        age = [ ];
        u2f = [ ];
      };
    }
  '';

  validRole = id: ''
    {
      id = "${id}";
      description = "test role";
      kind = "nixos";
      node_role = "compute";
      modules = [ ];
    }
  '';

  cases = {
    duplicate-id = {
      desc = "two entity files with the same `id` field throw";
      expectFail = true;
      files = {
        "users/alpha.nix" = validUser "shared";
        "users/beta.nix" = lib.replaceStrings [ ''username = "shared"'' ] [ ''username = "beta-acct"'' ] (
          validUser "shared"
        );
      };
    };

    missing-id = {
      desc = "entity file without an `id` field throws";
      expectFail = true;
      files = {
        "users/orphan.nix" = ''
          {
            kind = "human";
            cohort = "admin";
            headscale_user = "orphan";
            system_account = {
              username = "orphan";
              uid = 1000;
              shell = "bash";
            };
            keys = {
              ssh = [ ];
              age = [ ];
              u2f = [ ];
            };
          }
        '';
      };
    };

    basename-mismatch = {
      desc = "file basename != declared id throws";
      expectFail = true;
      files = {
        "users/wrong.nix" = validUser "right";
      };
    };

    host-class-personal-no-owner = {
      desc = "host with ownership.class=personal must declare an owner";
      expectFail = true;
      files = {
        "users/u-test.nix" = validUser "u-test";
        "roles/r-test.nix" = validRole "r-test";
        "teams/t-test.nix" = ''
          {
            id = "t-test";
            description = "test team";
            maintainers = [ "u-test" ];
            members = [
              {
                user = "u-test";
                role = "member";
              }
            ];
          }
        '';
        "hosts/personal/h-personal.nix" = ''
          {
            id = "h-personal";
            roles = [ "r-test" ];
            state = "provisioned";
            location.kind = "laptop";
            ownership = {
              class = "personal";
              team = "t-test";
            };
            hardware.arch = "x86_64-linux";
          }
        '';
      };
    };

    host-nic-unknown-network = {
      desc = "host.nics[].network must reference a declared network";
      expectFail = true;
      files = {
        "users/u-test.nix" = validUser "u-test";
        "roles/r-test.nix" = validRole "r-test";
        "hosts/lab/h-nicnet.nix" = ''
          {
            id = "h-nicnet";
            roles = [ "r-test" ];
            state = "provisioned";
            location.kind = "workstation";
            ownership = {
              class = "personal";
              owner = "u-test";
            };
            hardware.arch = "x86_64-linux";
            nics = [
              {
                name = "eth0";
                mac = "00:11:22:33:44:55";
                network = "nonexistent-network";
                role = "data";
              }
            ];
          }
        '';
      };
    };

    switch-port-unknown-peer = {
      desc = "switch port.peer must reference a host/switch (or be tagged external)";
      expectFail = true;
      files = {
        "users/u-test.nix" = validUser "u-test";
        "sites/s-test.nix" = ''
          {
            id = "s-test";
            description = "test site";
          }
        '';
        "racks/rk-test.nix" = ''
          {
            id = "rk-test";
            site = "s-test";
            description = "test rack";
          }
        '';
        "networks/net-mgmt.nix" = ''
          {
            id = "net-mgmt";
            kind = "mgmt";
            cidr_v4 = "10.0.0.0/24";
          }
        '';
        "switches/sw-test.nix" = ''
          {
            id = "sw-test";
            description = "test switch";
            role = "leaf";
            state = "provisioned";
            location = {
              kind = "switch-rack";
              rack = "rk-test";
              site = "s-test";
            };
            ownership = {
              class = "personal";
              owner = "u-test";
            };
            mgmt_ipv4 = "10.0.0.10/24";
            mgmt_network = "net-mgmt";
            hardware = {
              vendor = "test";
              model = "test-model";
              os = "openwrt";
            };
            ports.eth1 = {
              name = "eth1";
              role = "downlink-host";
              peer = "nonexistent-peer";
            };
          }
        '';
      };
    };

    switch-mgmt-network-unknown = {
      desc = "switch.mgmt_network must reference a declared network";
      expectFail = true;
      files = {
        "users/u-test.nix" = validUser "u-test";
        "sites/s-test.nix" = ''
          {
            id = "s-test";
            description = "test site";
          }
        '';
        "racks/rk-test.nix" = ''
          {
            id = "rk-test";
            site = "s-test";
            description = "test rack";
          }
        '';
        "switches/sw-test.nix" = ''
          {
            id = "sw-test";
            description = "test switch";
            role = "leaf";
            state = "provisioned";
            location = {
              kind = "switch-rack";
              rack = "rk-test";
              site = "s-test";
            };
            ownership = {
              class = "personal";
              owner = "u-test";
            };
            mgmt_network = "nonexistent-network";
            hardware = {
              vendor = "test";
              model = "test-model";
              os = "openwrt";
            };
          }
        '';
      };
    };

    minimal-valid = {
      desc = "a minimum-viable inventory loads without throwing";
      expectFail = false;
      files = {
        "users/u-test.nix" = validUser "u-test";
        "roles/r-test.nix" = validRole "r-test";
        "hosts/lab/h-min.nix" = ''
          {
            id = "h-min";
            roles = [ "r-test" ];
            state = "provisioned";
            location.kind = "workstation";
            ownership = {
              class = "personal";
              owner = "u-test";
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
      };
    };
  };

  runCase =
    name: case:
    let
      root = mkInventoryRoot name case.files;
      result = tryLoad root;
      threw = !result.success;
      pass = threw == case.expectFail;
      verdict = if pass then "PASS" else "FAIL";
      expected = if case.expectFail then "throw" else "clean load";
      actual = if threw then "threw" else "loaded";
    in
    "${verdict} ${name}: ${case.desc} (expected=${expected}, actual=${actual})";

  results = lib.mapAttrsToList runCase cases;
  failed = builtins.filter (lib.hasPrefix "FAIL ") results;

  summary = lib.concatStringsSep "\n" results;
in
pkgs.runCommand "inventory-validation"
  {
    inherit summary;
    failCount = toString (builtins.length failed);
  }
  ''
    set -euo pipefail
    echo "$summary"
    echo "-- $failCount failure(s) --"
    if [ "$failCount" != "0" ]; then
      echo "FAIL: at least one inventory-validation case did not behave as expected"
      exit 1
    fi
    echo "all inventory-validation cases passed" > "$out"
  ''
