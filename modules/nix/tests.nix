{ inputs, lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    let
      cephPkgs = pkgs.extend (
        _final: _prev: {
          inherit (inputs.nixpkgs-ceph.legacyPackages.${system}) ceph;
        }
      );
      testSuite = import ./checks/lib {
        inherit pkgs inputs cephPkgs;
        inherit (inputs) self;
      };
      fleetRootKey = "ssh-ed25519 AAAA-fleet-admin";
      kexecRootKeys = inputs.self.lib.mkKexecRootKeys {
        users = {
          fleet-admin = {
            admin_scopes = [ "fleet" ];
            archived = false;
            keys.ssh = [ fleetRootKey ];
          };
          archived-admin = {
            admin_scopes = [ "fleet" ];
            archived = true;
            keys.ssh = [ "ssh-ed25519 AAAA-archived-admin" ];
          };
          tailnet-admin = {
            admin_scopes = [ "tailnet" ];
            archived = false;
            keys.ssh = [ "ssh-ed25519 AAAA-tailnet-admin" ];
          };
        };
      };
    in
    {
      checks = {
        lib-eval =
          pkgs.runCommand "infra-lib-eval-stamp"
            {
              hasTypes = if inputs.self.lib ? types then "yes" else "no";
              hasMkInventory = if inputs.self.lib ? mkInventory then "yes" else "no";
              hasMkCodegen = if inputs.self.lib ? mkCodegen then "yes" else "no";
              hasMkHost = if inputs.self.lib ? mkHost then "yes" else "no";
              hasLegacyMkRole = if inputs.self.lib ? mkRole then "yes" else "no";
              fleetRootKeyOnly = if kexecRootKeys == [ fleetRootKey ] then "yes" else "no";
            }
            ''
              test "$hasMkHost" = yes
              test "$hasLegacyMkRole" = no
              test "$fleetRootKeyOnly" = yes
              echo "types=$hasTypes mkInventory=$hasMkInventory mkCodegen=$hasMkCodegen mkHost=$hasMkHost" > $out
            '';
      }
      // (lib.mapAttrs' (name: drv: lib.nameValuePair "test-${name}" drv) testSuite);

      apps = lib.mapAttrs' (
        name: drv:
        lib.nameValuePair "test-${name}" {
          type = "app";
          meta.description =
            if drv ? driver then
              "Run NixOS VM test ${name} via the interactive test driver"
            else
              "Build the ${name} check derivation";
          program =
            if drv ? driver then
              "${drv.driver}/bin/nixos-test-driver"
            else
              toString (
                pkgs.writeShellScript "run-test-${name}" ''
                  exec ${pkgs.nix}/bin/nix build --no-link --print-out-paths \
                    "${inputs.self}#checks.${system}.test-${name}"
                ''
              );
        }
      ) testSuite;
    };
}
