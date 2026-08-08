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
    in
    {
      checks = {
        lib-eval =
          pkgs.runCommand "infra-lib-eval-stamp"
            {
              hasTypes = if inputs.self.lib ? types then "yes" else "no";
              hasMkInventory = if inputs.self.lib ? mkInventory then "yes" else "no";
              hasMkCodegen = if inputs.self.lib ? mkCodegen then "yes" else "no";
              hasMkRole = if inputs.self.lib ? mkRole then "yes" else "no";
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
