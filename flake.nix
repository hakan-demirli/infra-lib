{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    impermanence.url = "github:nix-community/impermanence";
    srvos = {
      url = "github:numtide/srvos";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nur.url = "github:nix-community/NUR";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      { self, lib, ... }:
      let
        libDir = ./modules/lib;

        mkTypes = { lib }: import (libDir + "/types.nix") { inherit lib; };

        mkInventory =
          {
            lib,
            self,
            types,
          }:
          import (libDir + "/inventory.nix") { inherit lib self types; };

        mkCodegen = { lib, inventory }: import (libDir + "/codegen.nix") { inherit lib inventory; };

        mkRoleFn =
          {
            inputs,
            self,
            lib,
            inventory,
            libRoot ? ./.,
          }:
          import (libDir + "/mkRole.nix") {
            inherit
              inputs
              self
              lib
              inventory
              libRoot
              ;
          };

        mkKexecBundle =
          {
            inputs,
            system,
            rootKeys,
          }:
          (inputs.nixpkgs.lib.nixosSystem {
            inherit system;
            specialArgs = { inherit rootKeys; };
            modules = [ ./modules/ops/kexec.nix ];
          }).config.system.build.kexec_bundle;

        mkHostFacts =
          inventory:
          lib.mapAttrs (_hid: h: {
            inherit (h) id roles;
            system = h.hardware.arch;
            os = h.hardware.os;
            mainboard = h.hardware.mainboard or null;
            location = {
              inherit (h.location) kind;
              site = h.location.site or null;
            };
            cluster = inventory.hostToCluster.${h.id} or null;
            labels = h.labels or { };
          }) inventory.hosts;

        mkKexecRootKeys =
          inventory:
          lib.unique (
            lib.concatLists (
              lib.mapAttrsToList (_uid: u: if u.is_root_anywhere then u.keys.ssh else [ ]) inventory.users
            )
          );
      in
      {
        systems = [
          "x86_64-linux"
          "aarch64-linux"
          "aarch64-darwin"
          "x86_64-darwin"
        ];

        flake.lib = {
          types = mkTypes;
          inherit
            mkInventory
            mkCodegen
            mkHostFacts
            mkKexecRootKeys
            mkKexecBundle
            ;
          mkRole = mkRoleFn;
        };

        flake.nixosModules = {
          role-identity = ./modules/common/role-identity.nix;
          role-identity-darwin = ./modules/common/role-identity-darwin.nix;
          cluster-users = ./modules/common/cluster-users.nix;
          role-secrets = ./modules/common/role-secrets.nix;
          host-disko = ./modules/common/host-disko.nix;
          node-exporter = ./modules/common/node-exporter.nix;
          smartctl-exporter = ./modules/common/smartctl-exporter.nix;
          ipmi-exporter = ./modules/common/ipmi-exporter.nix;
          vector-shipper = ./modules/common/vector-shipper.nix;
          sshd = ./modules/common/sshd.nix;
          auto-upgrade = ./modules/common/auto-upgrade.nix;

          system-base = ./modules/system/base.nix;
          system-server-base = ./modules/system/server-base.nix;
          system-laptop-base = ./modules/system/laptop-base.nix;
          system-impermanence = ./modules/system/impermanence.nix;
          system-ephemeral-root = ./modules/system/ephemeral-root.nix;

          ops-kexec = ./modules/ops/kexec.nix;
        };

        perSystem =
          { pkgs, system, ... }:
          let
            statix-wrapper = pkgs.writeShellScriptBin "statix-fix" ''
              for path in "$@"; do
                ${pkgs.statix}/bin/statix fix "$path"
              done
            '';

            testSuite = import ./tests {
              inherit pkgs self inputs;
            };
          in
          {
            checks = {
              lib-eval =
                pkgs.runCommand "infra-lib-eval-stamp"
                  {
                    hasTypes = if self.lib ? types then "yes" else "no";
                    hasMkInventory = if self.lib ? mkInventory then "yes" else "no";
                    hasMkCodegen = if self.lib ? mkCodegen then "yes" else "no";
                    hasMkRole = if self.lib ? mkRole then "yes" else "no";
                  }
                  ''
                    echo "types=$hasTypes mkInventory=$hasMkInventory mkCodegen=$hasMkCodegen mkRole=$hasMkRole" > $out
                  '';
            }
            // (lib.mapAttrs' (name: drv: lib.nameValuePair "test-${name}" drv) testSuite);

            apps = lib.mapAttrs' (
              name: drv:
              lib.nameValuePair "test-${name}" {
                type = "app";
                program =
                  if drv ? driver then
                    "${drv.driver}/bin/nixos-test-driver"
                  else
                    toString (
                      pkgs.writeShellScript "run-test-${name}" ''
                        exec ${pkgs.nix}/bin/nix build --no-link --print-out-paths \
                          "${self}#checks.${system}.test-${name}"
                      ''
                    );
              }
            ) testSuite;

            devShells.default = pkgs.mkShellNoCC {
              packages = with pkgs; [
                nixVersions.latest
                nix-output-monitor
                nixfmt
                statix
                deadnix
                taplo
                jq
                gitMinimal
              ];
            };

            formatter = pkgs.treefmt.withConfig {
              runtimeInputs = with pkgs; [
                nixfmt
                deadnix
                statix
                taplo
              ];

              settings = {
                on-unmatched = "info";
                tree-root-file = "flake.nix";

                global.excludes = [
                  "flake.lock"
                  ".direnv/**"
                  "result"
                  "result-*"
                  "*.md"
                ];

                formatter = {
                  deadnix = {
                    command = "deadnix";
                    options = [ "--edit" ];
                    includes = [ "*.nix" ];
                    priority = 1;
                  };
                  statix = {
                    command = "${statix-wrapper}/bin/statix-fix";
                    includes = [ "*.nix" ];
                    priority = 2;
                  };
                  nixfmt = {
                    command = "nixfmt";
                    includes = [ "*.nix" ];
                    priority = 3;
                  };
                  taplo = {
                    command = "taplo";
                    options = [ "fmt" ];
                    includes = [ "*.toml" ];
                  };
                };
              };
            };
          };
      }
    );
}
