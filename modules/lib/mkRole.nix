{
  inputs,
  self,
  libRoot,
  lib,
  inventory,
}:
with lib;
let
  resolveModule =
    ref:
    findFirst pathExists null [
      (self + "/modules/roles/${ref}.nix")
      (self + "/modules/services/${ref}.nix")
      (self + "/modules/common/${ref}.nix")
      (self + "/modules/${ref}.nix")
      (libRoot + "/modules/roles/${ref}.nix")
      (libRoot + "/modules/services/${ref}.nix")
      (libRoot + "/modules/common/${ref}.nix")
      (libRoot + "/modules/${ref}.nix")
    ];

  baseLinuxModules = [
    inputs.sops-nix.nixosModules.sops
    inputs.disko.nixosModules.disko
    inputs.impermanence.nixosModules.impermanence
    (libRoot + "/modules/common/role-identity.nix")
    (libRoot + "/modules/common/cluster-users.nix")
    (libRoot + "/modules/common/role-secrets.nix")
    (libRoot + "/modules/common/host-disko.nix")
    (libRoot + "/modules/common/node-exporter.nix")
    (libRoot + "/modules/common/smartctl-exporter.nix")
    (libRoot + "/modules/common/ipmi-exporter.nix")
    (libRoot + "/modules/common/vector-shipper.nix")
    (libRoot + "/modules/common/sshd.nix")
    (libRoot + "/modules/common/overlays.nix")
  ];

  srvosIfServer =
    host:
    let
      isServer = elem host.location.kind [ "rack" ];
    in
    optional isServer inputs.srvos.nixosModules.server;

  baseDarwinModules = optional (inputs ? nix-darwin) (
    libRoot + "/modules/common/role-identity-darwin.nix"
  );

  roleModulesFor =
    host:
    let
      sortedRoles = sort lessThan host.roles;
      specs = map (r: inventory.roles.${r}) sortedRoles;
      refs = concatLists (map (s: s.modules) specs);
      resolved = filter (p: p != null) (map resolveModule refs);
    in
    unique resolved;

  combinedTunables =
    host:
    foldl' recursiveUpdate { } (map (r: inventory.roles.${r}.tunables) (sort lessThan host.roles))
    // host.tunables;

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
        consumerPath = self + "/modules/hardware/${host.hardware.mainboard}.nix";
        libPath = libRoot + "/modules/hardware/${host.hardware.mainboard}.nix";
      in
      if pathExists consumerPath then
        [ consumerPath ]
      else if pathExists libPath then
        [ libPath ]
      else
        [ ];

  nixosHardwareModule =
    host:
    let
      quirk = host.labels.nixos_hardware or null;
    in
    if quirk == null then
      [ ]
    else if !(inputs ? nixos-hardware) then
      [ ]
    else
      let
        p = inputs.nixos-hardware + "/${quirk}";
      in
      optional (pathExists p) p;

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
        ++ roleModulesFor host
        ++ hostOverride host
        ++ [
          (_: {
            cluster.host = {
              inherit (host)
                id
                roles
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
                mounts
                slurm_features
                slurm_gres
                slurm_weight
                ;
              tunables = combinedTunables host;
              inherit (host) cluster;
            };
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
          ++ roleModulesFor host
          ++ hostOverride host
          ++ [
            (_: {
              cluster.host = {
                inherit (host)
                  id
                  roles
                  hardware
                  location
                  ownership
                  lifecycle
                  asset
                  labels
                  ;
                tunables = combinedTunables host;
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
      ++ roleModulesFor host
      ++ hostOverride host;
  }) (filterAttrs (_: h: isNixosHost h && buildable h) inventory.hosts);
}
