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
    builtins.tryEval (builtins.deepSeq inv.deploymentRoles (builtins.deepSeq inv.hosts inv));

  validUser = id: ''
    {
      id = "${id}";
      kind = "human";
      cohort = "staff";
      admin_scopes = [ ];
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

  validDeploymentRole = id: ''
    {
      id = "${id}";
      description = "test deployment role";
      kind = "nixos";
      modules = [ ];
    }
  '';

  validUnixTier = id: ''
    {
      id = "${id}";
      description = "test Unix access tier";
      groups = [ ];
      sudo.extra_rule = null;
      ssh.allowed = true;
      root_ssh = false;
    }
  '';

  validHost = id: extra: ''
    {
      id = "${id}";
      deployment_roles = [ "compute-role" ];
      topology_roles = [ "compute" ];
      state = "provisioned";
      location.kind = "workstation";
      ownership = {
        class = "personal";
        owner = "inventory-user";
      };
      hardware = {
        arch = "x86_64-linux";
        cpu_vendor = "amd";
        cpu_sockets = 1;
        cpu_cores_per_socket = 4;
        cpu_threads_per_core = 2;
        ram_mib = 16384;
      };
      ${extra}
    }
  '';

  cases = {
    duplicate-id = {
      desc = "two entity files with the same `id` field throw";
      expectFail = true;
      files = {
        "users/duplicate-user-a.nix" = validUser "shared-user";
        "users/duplicate-user-b.nix" =
          lib.replaceStrings [ ''username = "shared-user"'' ] [ ''username = "duplicate-user-b"'' ]
            (validUser "shared-user");
      };
    };

    missing-id = {
      desc = "entity file without an `id` field throws";
      expectFail = true;
      files = {
        "users/orphan.nix" = ''
          {
            kind = "human";
            cohort = "staff";
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
        "users/inventory-user.nix" = validUser "inventory-user";
        "deployment-roles/compute-role.nix" = validDeploymentRole "compute-role";
        "teams/t-test.nix" = ''
          {
            id = "t-test";
            description = "test team";
            maintainers = [ "inventory-user" ];
            members = [
              {
                user = "inventory-user";
                role = "member";
              }
            ];
          }
        '';
        "hosts/personal/h-personal.nix" = ''
          {
            id = "h-personal";
            deployment_roles = [ "compute-role" ];
            topology_roles = [ "compute" ];
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
        "users/inventory-user.nix" = validUser "inventory-user";
        "deployment-roles/compute-role.nix" = validDeploymentRole "compute-role";
        "hosts/lab/h-nicnet.nix" = ''
          {
            id = "h-nicnet";
            deployment_roles = [ "compute-role" ];
            topology_roles = [ "compute" ];
            state = "provisioned";
            location.kind = "workstation";
            ownership = {
              class = "personal";
              owner = "inventory-user";
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
        "users/inventory-user.nix" = validUser "inventory-user";
        "sites/test-site.nix" = ''
          {
            id = "test-site";
            description = "test site";
          }
        '';
        "racks/rk-test.nix" = ''
          {
            id = "rk-test";
            site = "test-site";
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
              site = "test-site";
            };
            ownership = {
              class = "personal";
              owner = "inventory-user";
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
        "users/inventory-user.nix" = validUser "inventory-user";
        "sites/test-site.nix" = ''
          {
            id = "test-site";
            description = "test site";
          }
        '';
        "racks/rk-test.nix" = ''
          {
            id = "rk-test";
            site = "test-site";
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
              site = "test-site";
            };
            ownership = {
              class = "personal";
              owner = "inventory-user";
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

    impermanence-requires-supported-layout = {
      desc = "enabled impermanence requires managed btrfs-lvm";
      expectFail = true;
      files = {
        "users/inventory-user.nix" = validUser "inventory-user";
        "deployment-roles/compute-role.nix" = validDeploymentRole "compute-role";
        "hosts/lab/h-impermanent.nix" = validHost "h-impermanent" ''
          disko = {
            root_disk = "/dev/vda";
            layout = "ext4-single";
            managed = true;
          };
          impermanence.enable = true;
        '';
      };
    };

    installer-requires-stable-managed-disk = {
      desc = "installer opt-in requires managed Disko with a stable by-id disk";
      expectFail = true;
      files = {
        "users/inventory-user.nix" = validUser "inventory-user";
        "deployment-roles/compute-role.nix" = validDeploymentRole "compute-role";
        "hosts/lab/h-installer.nix" = validHost "h-installer" ''
          disko = {
            root_disk = "/dev/vda";
            layout = "ext4-single";
            managed = true;
            installer.enable = true;
          };
        '';
      };
    };

    installer-accepts-stable-managed-disk = {
      desc = "installer opt-in accepts a managed Linux host with a by-id disk";
      expectFail = false;
      files = {
        "users/inventory-user.nix" = validUser "inventory-user";
        "deployment-roles/compute-role.nix" = validDeploymentRole "compute-role";
        "hosts/lab/h-installer.nix" = validHost "h-installer" ''
          disko = {
            root_disk = "/dev/disk/by-id/test-installer-disk";
            layout = "ext4-single";
            managed = true;
            installer.enable = true;
          };
        '';
      };
    };

    impermanence-disabled-rejects-payload = {
      desc = "disabled impermanence rejects persistence payload";
      expectFail = true;
      files = {
        "users/inventory-user.nix" = validUser "inventory-user";
        "deployment-roles/compute-role.nix" = validDeploymentRole "compute-role";
        "hosts/lab/h-persist.nix" = validHost "h-persist" ''
          impermanence.persisted_paths = [ "/var/log" ];
        '';
      };
    };

    monitoring-disabled-rejects-always-on = {
      desc = "disabled monitoring rejects always_on=true";
      expectFail = true;
      files = {
        "users/inventory-user.nix" = validUser "inventory-user";
        "deployment-roles/compute-role.nix" = validDeploymentRole "compute-role";
        "hosts/lab/h-monitor.nix" = validHost "h-monitor" ''
          monitoring = {
            enabled = false;
            always_on = true;
          };
        '';
      };
    };

    slurm-node-attributes-require-partition = {
      desc = "Slurm node fields require partition membership";
      expectFail = true;
      files = {
        "users/inventory-user.nix" = validUser "inventory-user";
        "deployment-roles/compute-role.nix" = validDeploymentRole "compute-role";
        "hosts/lab/h-slurm-fields.nix" = validHost "h-slurm-fields" ''
          slurm_features = [ "gpu" ];
        '';
      };
    };

    orphan-ssh-trust-intent = {
      desc = "ssh_trust_intent requires a matching ssh_trust key";
      expectFail = true;
      files = {
        "users/inventory-user.nix" = validUser "inventory-user";
        "deployment-roles/compute-role.nix" = validDeploymentRole "compute-role";
        "hosts/lab/h-ssh-intent.nix" = validHost "h-ssh-intent" ''
          ssh_trust_intent.root.allow_paths = [ "lan" ];
        '';
      };
    };

    deployment-role-rejects-removed-tunables = {
      desc = "unimplemented deployment role tunables are rejected by the schema";
      expectFail = true;
      files = {
        "deployment-roles/compute-role.nix" = ''
          {
            id = "compute-role";
            tunables = { };
          }
        '';
      };
    };

    deployment-role-requires-explicit-module-owner = {
      desc = "deployment role module references require an infra: or self: owner";
      expectFail = true;
      files."deployment-roles/compute-role.nix" = ''
        {
          id = "compute-role";
          modules = [ "services/base" ];
        }
      '';
    };

    deployment-role-rejects-path-traversal = {
      desc = "deployment role module references cannot escape their modules root";
      expectFail = true;
      files."deployment-roles/compute-role.nix" = ''
        {
          id = "compute-role";
          modules = [ "self:services/../../outside" ];
        }
      '';
    };

    host-requires-explicit-topology-role = {
      desc = "a buildable host cannot infer topology from deployment composition";
      expectFail = true;
      files = {
        "users/inventory-user.nix" = validUser "inventory-user";
        "deployment-roles/compute-role.nix" = validDeploymentRole "compute-role";
        "hosts/lab/h-no-topology.nix" = ''
          {
            id = "h-no-topology";
            deployment_roles = [ "compute-role" ];
            topology_roles = [ ];
            state = "provisioned";
            location.kind = "workstation";
            ownership = {
              class = "personal";
              owner = "inventory-user";
            };
            hardware = {
              arch = "x86_64-linux";
              cpu_vendor = "amd";
              cpu_sockets = 1;
              cpu_cores_per_socket = 2;
              cpu_threads_per_core = 1;
              ram_mib = 2048;
            };
          }
        '';
      };
    };

    removed-admin-cohort-is-rejected = {
      desc = "global administration cannot be encoded as an identity cohort";
      expectFail = true;
      files."users/legacy-admin.nix" = ''
        {
          id = "legacy-admin";
          cohort = "admin";
        }
      '';
    };

    conflicting-unix-tiers-are-rejected = {
      desc = "one user cannot resolve to conflicting Unix tiers on a cluster";
      expectFail = true;
      files = {
        "users/inventory-user.nix" = validUser "inventory-user";
        "deployment-roles/compute-role.nix" = validDeploymentRole "compute-role";
        "unix-access-tiers/admin.nix" = validUnixTier "admin";
        "unix-access-tiers/viewer.nix" = validUnixTier "viewer";
        "teams/tier-team.nix" = ''
          {
            id = "tier-team";
            members = [
              {
                user = "inventory-user";
                role = "member";
              }
            ];
          }
        '';
        "hosts/lab/h-tier-conflict.nix" = validHost "h-tier-conflict" "";
        "clusters/c-tier-conflict.nix" = ''
          {
            id = "c-tier-conflict";
            ownership = {
              class = "personal";
              owner = "inventory-user";
            };
            members.hosts = [ "h-tier-conflict" ];
            access.teams = [
              {
                team = "tier-team";
                unix_tier = "admin";
              }
            ];
            access.users = [
              {
                user = "inventory-user";
                unix_tier = "viewer";
              }
            ];
          }
        '';
      };
    };

    unix-tier-map-rejects-unknown-team-role = {
      desc = "team Unix-tier maps accept only declared team roles and default";
      expectFail = true;
      files = {
        "users/inventory-user.nix" = validUser "inventory-user";
        "unix-access-tiers/admin.nix" = validUnixTier "admin";
        "teams/tier-team.nix" = ''
          {
            id = "tier-team";
            members = [
              {
                user = "inventory-user";
                role = "member";
              }
            ];
          }
        '';
        "clusters/c-tier-map.nix" = ''
          {
            id = "c-tier-map";
            ownership = {
              class = "personal";
              owner = "inventory-user";
            };
            access.teams = [
              {
                team = "tier-team";
                unix_tier = {
                  default = "admin";
                  operator = "admin";
                };
              }
            ];
          }
        '';
      };
    };

    unix-tier-rejects-root-when-ssh-is-denied = {
      desc = "a Unix tier cannot propagate root keys while denying SSH";
      expectFail = true;
      files."unix-access-tiers/contradictory.nix" = ''
        {
          id = "contradictory";
          ssh.allowed = false;
          root_ssh = true;
        }
      '';
    };

    scheduler-none-rejects-slurm-payload = {
      desc = "scheduler.kind=none rejects Slurm controllers";
      expectFail = true;
      files = {
        "users/inventory-user.nix" = validUser "inventory-user";
        "deployment-roles/compute-role.nix" = validDeploymentRole "compute-role";
        "hosts/lab/h-scheduler.nix" = validHost "h-scheduler" "";
        "clusters/c-test.nix" = ''
          {
            id = "c-test";
            ownership = {
              class = "personal";
              owner = "inventory-user";
            };
            members.hosts = [ "h-scheduler" ];
            scheduler = {
              kind = "none";
              controllers = [ "h-scheduler" ];
            };
          }
        '';
      };
    };

    cluster-fs-rejects-unselected-payload = {
      desc = "cluster_fs accepts exactly the selected backend payload";
      expectFail = true;
      files = {
        "users/inventory-user.nix" = validUser "inventory-user";
        "deployment-roles/compute-role.nix" = validDeploymentRole "compute-role";
        "hosts/lab/h-fs.nix" = validHost "h-fs" "";
        "clusters/c-fs.nix" = ''
          {
            id = "c-fs";
            ownership = {
              class = "personal";
              owner = "inventory-user";
            };
            members.hosts = [ "h-fs" ];
            cluster_fs = {
              backend = "nfs";
              nfs = {
                server = "nfs.example";
                export = "/srv/data";
              };
              cephfs = {
                fsid = "00000000-0000-0000-0000-000000000000";
                monitors = [ "mon-0:6789" ];
              };
            };
          }
        '';
      };
    };

    virt-guest-requires-tagged-payload = {
      desc = "kvm-guest location requires virt.role=guest and complete guest payload";
      expectFail = true;
      files = {
        "users/inventory-user.nix" = validUser "inventory-user";
        "deployment-roles/compute-role.nix" = validDeploymentRole "compute-role";
        "hosts/lab/h-guest.nix" = ''
          {
            id = "h-guest";
            deployment_roles = [ "compute-role" ];
            topology_roles = [ "compute" ];
            state = "provisioned";
            location.kind = "kvm-guest";
            ownership = {
              class = "personal";
              owner = "inventory-user";
            };
            hardware = {
              arch = "x86_64-linux";
              cpu_vendor = "amd";
              cpu_sockets = 1;
              cpu_cores_per_socket = 2;
              cpu_threads_per_core = 1;
              ram_mib = 2048;
            };
          }
        '';
      };
    };

    minimal-valid = {
      desc = "a minimum-viable inventory loads without throwing";
      expectFail = false;
      files = {
        "users/inventory-user.nix" = validUser "inventory-user";
        "deployment-roles/compute-role.nix" = validDeploymentRole "compute-role";
        "hosts/lab/h-min.nix" = ''
          {
            id = "h-min";
            deployment_roles = [ "compute-role" ];
            topology_roles = [ "compute" ];
            state = "provisioned";
            location.kind = "workstation";
            ownership = {
              class = "personal";
              owner = "inventory-user";
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
