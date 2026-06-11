{ lib, ... }:
let
  libDir = ../lib;

  mkTypes = { lib }: import (libDir + "/types.nix") { inherit lib; };

  mkInventory =
    {
      lib,
      self,
      types,
    }:
    import (libDir + "/inventory.nix") { inherit lib self types; };

  mkCodegen = { lib, inventory }: import (libDir + "/codegen.nix") { inherit lib inventory; };

  mkIntent = { lib, inventory }: import (libDir + "/intent.nix") { inherit lib inventory; };

  mkRoleFn =
    {
      inputs,
      self,
      lib,
      inventory,
      libRoot ? ../..,
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
      modules = [ ../ops/kexec.nix ];
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
        lib.mapAttrsToList (_uid: u: if u.cohort == "admin" then u.keys.ssh else [ ]) inventory.users
      )
    );
in
{
  flake.lib = {
    types = mkTypes;
    inherit
      mkInventory
      mkCodegen
      mkIntent
      mkHostFacts
      mkKexecRootKeys
      mkKexecBundle
      ;
    mkRole = mkRoleFn;
  };
}
