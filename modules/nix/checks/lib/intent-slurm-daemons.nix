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

  loadInventory =
    root:
    import (self + "/modules/lib/inventory.nix") {
      inherit lib;
      types = import (self + "/modules/lib/types.nix") { inherit lib; };
      self = root;
    };

  mkHost = id: deploymentRole: topologyRoles: ''
    {
      id = "${id}";
      deployment_roles = [ "${deploymentRole}" ];
      topology_roles = [ ${lib.concatMapStringsSep " " (role: ''"${role}"'') topologyRoles} ];
      state = "provisioned";
      location.kind = "workstation";
      ownership = {
        class = "personal";
        owner = "u-owner";
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

  mkRole = id: module: ''
    {
      id = "${id}";
      description = "test deployment role";
      kind = "nixos";
      modules = [ "${module}" ];
    }
  '';

  mkRoot =
    name: nodeBRoles:
    mkInventoryRoot name {
      "users/u-owner.nix" = ''
        {
          id = "u-owner";
          kind = "human";
          cohort = "staff";
          admin_scopes = [ "tailnet" ];
          headscale_user = "u-owner";
          allowed_hosts = [ "all" ];
          system_account = {
            username = "u-owner";
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
      "deployment-roles/slurm-server.nix" = mkRole "slurm-server" "infra:services/slurm";
      "deployment-roles/slurm-submit.nix" = mkRole "slurm-submit" "infra:services/slurm-client";
      "hosts/lab/ctrl.nix" = mkHost "ctrl" "slurm-server" [ "controller" ];
      "hosts/lab/node-a.nix" = mkHost "node-a" "slurm-server" [ "compute" ];
      "hosts/lab/node-b.nix" = mkHost "node-b" "slurm-server" nodeBRoles;
      "hosts/lab/desk.nix" = mkHost "desk" "slurm-submit" [ "admin-client" ];
      "clusters/c-slurm.nix" = ''
        {
          id = "c-slurm";
          ownership = {
            class = "personal";
            owner = "u-owner";
          };
          members.hosts = [
            "ctrl"
            "node-a"
            "node-b"
            "desk"
          ];
          scheduler = {
            kind = "slurm";
            controllers = [ "ctrl" ];
            partitions.main = {
              nodes = [
                "node-a"
                "node-b"
              ];
              default = true;
            };
          };
        }
      '';
    };

  validInventory = loadInventory (mkRoot "slurm-valid" [ "compute" ]);
  valid = import (self + "/modules/lib/intent.nix") {
    inherit lib;
    inventory = validInventory;
  };
  broken = import (self + "/modules/lib/intent.nix") {
    inherit lib;
    inventory = loadInventory (mkRoot "slurm-untagged-node" [ "login" ]);
  };

  daemonViolations =
    intent: lib.filter (v: v.kind == "slurm-daemon-no-tailnet") intent.intentViolations;
  slurmRules = lib.filter (
    rule:
    lib.elem rule.reason [
      "slurmctld"
      "slurmd"
      "srun"
    ]
  ) valid.aclRules;

  policy = "${
    (import (self + "/modules/lib/codegen.nix") {
      inherit lib;
      inventory = validInventory;
    }).headscaleAcl
      { inherit pkgs; }
  }/policy.hujson";

  checks = {
    reachable-cluster-has-no-daemon-violation = daemonViolations valid == [ ];
    untagged-node-is-unreachable-by-slurmctld = lib.any (
      v: v.src == "ctrl" && v.host == "node-b" && v.port == "6818"
    ) (daemonViolations broken);
    admin-client-receives-srun-callbacks = lib.any (
      rule: rule.reason == "srun" && rule.dst == "tag:fleet-admin-client"
    ) slurmRules;
  };

  failures = lib.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
pkgs.runCommand "intent-slurm-daemons"
  {
    nativeBuildInputs = [ pkgs.jq ];
    failureCount = toString (lib.length failures);
    failureNames = lib.concatStringsSep "," failures;
    rules = builtins.toJSON slurmRules;
    passAsFile = [ "rules" ];
  }
  ''
    if [ "$failureCount" != 0 ]; then
      echo "failed intent slurm-daemon checks: $failureNames" >&2
      exit 1
    fi
    grep -v '^//' ${policy} > policy.json
    jq -e --slurpfile rules "$rulesPath" '
      .acls as $acls
      | ($rules[0] | length) == 4
      and ($rules[0] | all(
          . as $rule
          | $acls | any(
              .action == "accept"
              and (.src | contains($rule.src))
              and (.dst | index("\($rule.dst):\($rule.port)") != null)
            )
        ))
    ' policy.json > /dev/null || {
      echo "generated headscale policy does not contain every intent slurm rule" >&2
      exit 1
    }
    touch "$out"
  ''
