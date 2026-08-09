{ lib, ... }:
let
  libDir = ../lib;

  hujson = import (libDir + "/hujson.nix") { inherit lib; };
  headscalePolicy = import (libDir + "/headscale-policy.nix") {
    inherit lib hujson;
  };

  mkTypes = { lib }: import (libDir + "/types.nix") { inherit lib; };

  mkInventory =
    {
      lib,
      self,
      types,
    }:
    import (libDir + "/inventory.nix") { inherit lib self types; };

  mkCodegen =
    { lib, inventory }:
    import (libDir + "/codegen.nix") {
      inherit lib inventory headscalePolicy;
    };

  mkIntent = { lib, inventory }: import (libDir + "/intent.nix") { inherit lib inventory; };

  mkHostFn =
    {
      inputs,
      self,
      lib,
      inventory,
      libRoot ? ../..,
    }:
    import (libDir + "/mkHost.nix") {
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
      extraModules ? [ ],
    }:
    (inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit rootKeys; };
      modules = [ ../ops/kexec.nix ] ++ extraModules;
    }).config.system.build.kexec_bundle;

  mkDiskoInstallerBundle =
    {
      inputs,
      system,
      rootKeys,
      hostId,
      expectedDisk,
      targetSystem,
      diskoScript,
    }:
    let
      installer = {
        inherit
          diskoScript
          expectedDisk
          hostId
          targetSystem
          ;
      };
      evaluated = inputs.nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit installer rootKeys;
        };
        modules = [
          ../ops/kexec.nix
          ../ops/disko-installer.nix
        ];
      };
      bundle = evaluated.config.system.build.kexec_bundle;
      installerSquashfs = evaluated.config.system.build.squashfsStore;
      squashfsManifest = evaluated.config.system.build.installerSquashfsManifest;
      assemblyService = evaluated.config.boot.initrd.systemd.services.assemble-installer-squashfs;
    in
    bundle
    // {
      inherit
        diskoScript
        expectedDisk
        hostId
        targetSystem
        ;
      inherit installerSquashfs squashfsManifest;
      initrdMode = "staged-squashfs";
      assemblyRequiredBy = assemblyService.requiredBy;
      assemblyRemainAfterExit = assemblyService.serviceConfig.RemainAfterExit;
      assemblyScript = assemblyService.script;
      installScript = evaluated.config.systemd.services.disko-installer.script;
      kernelMarker = "infra.install=${hostId}";
      passthru = (bundle.passthru or { }) // {
        inherit
          diskoScript
          expectedDisk
          hostId
          targetSystem
          ;
        inherit installerSquashfs squashfsManifest;
        initrdMode = "staged-squashfs";
        assemblyRequiredBy = assemblyService.requiredBy;
        assemblyRemainAfterExit = assemblyService.serviceConfig.RemainAfterExit;
        assemblyScript = assemblyService.script;
        installScript = evaluated.config.systemd.services.disko-installer.script;
        kernelMarker = "infra.install=${hostId}";
      };
    };

  mkHostFacts =
    inventory:
    lib.mapAttrs (_hid: h: {
      inherit (h) id;
      deploymentRoles = h.deployment_roles;
      topologyRoles = h.topology_roles;
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
        lib.mapAttrsToList (
          _uid: u: if lib.elem "fleet" u.admin_scopes && !(u.archived or false) then u.keys.ssh else [ ]
        ) inventory.users
      )
    );
in
{
  flake.lib = {
    types = mkTypes;
    inherit
      hujson
      headscalePolicy
      mkInventory
      mkCodegen
      mkIntent
      mkHostFacts
      mkKexecRootKeys
      mkKexecBundle
      mkDiskoInstallerBundle
      ;
    mkHost = mkHostFn;
  };
}
