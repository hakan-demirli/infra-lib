{
  inputs,
  self,
  libRoot,
  lib,
  inventory,
}:
with lib;
let
  moduleCandidates =
    ref:
    let
      parsed = builtins.match "^(infra|self):([a-z0-9][a-z0-9_.-]*(/[a-z0-9][a-z0-9_.-]*)*)$" ref;
      source = elemAt parsed 0;
      relative = elemAt parsed 1;
      root = if source == "infra" then libRoot else self;
    in
    if parsed == null then
      throw "mkHost: module reference '${ref}' must use an explicit infra: or self: owner and a safe relative path"
    else
      [
        (root + "/modules/${relative}.nix")
        (root + "/modules/${relative}/default.nix")
      ];

  resolveModule =
    ref:
    let
      candidates = moduleCandidates ref;
      hit = findFirst pathExists null candidates;
    in
    if hit != null then
      hit
    else
      throw ''
        mkHost: cannot resolve explicit module reference '${ref}'.
        Searched:
        ${concatStringsSep "\n" (map (p: "  - ${toString p}") candidates)}
      '';

  baseLinuxModules = [
    inputs.sops-nix.nixosModules.sops
    inputs.disko.nixosModules.disko
    inputs.impermanence.nixosModules.impermanence
    (libRoot + "/modules/common/host-identity.nix")
    (libRoot + "/modules/common/cluster-users.nix")
    (libRoot + "/modules/common/deployment-role-secrets.nix")
    (libRoot + "/modules/common/host-disko.nix")
    (libRoot + "/modules/common/node-exporter.nix")
    (libRoot + "/modules/common/smartctl-exporter.nix")
    (libRoot + "/modules/common/ipmi-exporter.nix")
    (libRoot + "/modules/common/vector-shipper.nix")
    (libRoot + "/modules/common/sshd.nix")
    (libRoot + "/modules/common/overlays.nix")
    (libRoot + "/modules/system/impermanence.nix")
    (libRoot + "/modules/system/ephemeral-root.nix")
    (libRoot + "/modules/system/home-storage")
  ];

  srvosIfServer =
    host:
    let
      isServer = elem host.location.kind [ "rack" ];
    in
    optional isServer inputs.srvos.nixosModules.server;

  baseDarwinModules = optional (inputs ? nix-darwin) (
    libRoot + "/modules/common/host-identity-darwin.nix"
  );

  deploymentRoleModulesFor =
    host:
    let
      sortedDeploymentRoles = sort lessThan host.deployment_roles;
      resolveForDeploymentRole =
        deploymentRoleId: ref:
        let
          candidates = moduleCandidates ref;
          hit = findFirst pathExists null candidates;
        in
        if hit != null then
          hit
        else
          throw ''
            mkHost: host '${host.id}' deployment role '${deploymentRoleId}' references module '${ref}' which does not exist.
            Searched:
            ${concatStringsSep "\n" (map (p: "  - ${toString p}") candidates)}
          '';
      resolved = concatMap (
        deploymentRoleId:
        let
          spec = inventory.deploymentRoles.${deploymentRoleId};
        in
        map (resolveForDeploymentRole deploymentRoleId) spec.modules
      ) sortedDeploymentRoles;
    in
    unique resolved;

  hostOverride =
    host:
    let
      p = self + "/modules/hosts/${host.id}.nix";
    in
    optional (pathExists p) p;

  mainboardModule =
    host:
    if host.hardware.mainboard == null then
      [ ]
    else
      let
        mb = host.hardware.mainboard;
        consumerPath = self + "/modules/hardware/${mb}.nix";
        libPath = libRoot + "/modules/hardware/${mb}.nix";
      in
      if pathExists consumerPath then
        [ consumerPath ]
      else if pathExists libPath then
        [ libPath ]
      else
        throw ''
          mkHost: host '${host.id}' declares hardware.mainboard='${mb}' but no matching module exists.
          Searched (in order):
            - ${toString consumerPath}
            - ${toString libPath}
        '';

  nixosHardwareModule =
    host:
    let
      quirk = host.labels.nixos_hardware or null;
    in
    if quirk == null then
      [ ]
    else if !(inputs ? nixos-hardware) then
      throw "mkHost: host '${host.id}' declares labels.nixos_hardware='${quirk}' but inputs.nixos-hardware is not wired into the flake."
    else
      let
        p = inputs.nixos-hardware + "/${quirk}";
      in
      if pathExists p then
        [ p ]
      else
        throw "mkHost: host '${host.id}' declares labels.nixos_hardware='${quirk}' but nixos-hardware has no such path (${toString p}).";

  buildNixos =
    host:
    inputs.nixpkgs.lib.nixosSystem {
      system = host.hardware.arch;
      specialArgs = {
        inherit inputs self;
        cluster = inventory;
        inherit host;
        hostName = host.id;
      };
      modules =
        baseLinuxModules
        ++ srvosIfServer host
        ++ mainboardModule host
        ++ nixosHardwareModule host
        ++ deploymentRoleModulesFor host
        ++ hostOverride host
        ++ [
          (_: {
            cluster.host = {
              inherit (host)
                id
                deployment_roles
                topology_roles
                hardware
                location
                ownership
                lifecycle
                asset
                nics
                bmc
                disko
                ceph
                boot
                impermanence
                labels
                bgp
                slurm_features
                slurm_gres
                slurm_weight
                ;
              inherit (host) cluster;
            };
            system.configurationRevision = self.rev or self.dirtyRev or self.narHash or null;
          })
        ];
    };

  buildDarwin =
    host:
    if !(inputs ? nix-darwin) then
      throw "host '${host.id}' has arch '${host.hardware.arch}' but inputs.nix-darwin is missing"
    else
      inputs.nix-darwin.lib.darwinSystem {
        system = host.hardware.arch;
        specialArgs = {
          inherit inputs self;
          cluster = inventory;
          inherit host;
          hostName = host.id;
        };
        modules =
          baseDarwinModules
          ++ mainboardModule host
          ++ deploymentRoleModulesFor host
          ++ hostOverride host
          ++ [
            (_: {
              cluster.host = {
                inherit (host)
                  id
                  deployment_roles
                  topology_roles
                  hardware
                  location
                  ownership
                  lifecycle
                  asset
                  labels
                  ;
                inherit (host) cluster;
              };
            })
          ];
      };

  isNixosHost = h: h.hardware.os == "linux";
  isDarwinHost = h: h.hardware.os == "darwin";

  mkHost =
    host:
    if isNixosHost host then
      buildNixos host
    else if isDarwinHost host then
      buildDarwin host
    else
      throw "host '${host.id}' has unsupported os '${host.hardware.os}' for closure build";

  buildable =
    h:
    !(elem h.state [
      "retired"
      "decommissioned"
      "planned"
    ]);

in
{
  inherit mkHost resolveModule;

  nixosConfigurations = mapAttrs (_: mkHost) (
    filterAttrs (_: h: isNixosHost h && buildable h) inventory.hosts
  );

  darwinConfigurations = mapAttrs (_: mkHost) (
    filterAttrs (_: h: isDarwinHost h && buildable h) inventory.hosts
  );

  nixosModules = mapAttrs (_: host: {
    imports =
      baseLinuxModules
      ++ mainboardModule host
      ++ nixosHardwareModule host
      ++ deploymentRoleModulesFor host
      ++ hostOverride host;
  }) (filterAttrs (_: h: isNixosHost h && buildable h) inventory.hosts);
}
