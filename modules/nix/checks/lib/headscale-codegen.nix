{ pkgs, self }:
let
  testlib = import ./lib.nix { inherit pkgs; };
  inventory = {
    hosts = { };
    deploymentRoles = { };
    networks = { };
    activeDeploymentRoles = [ ];
    teams = { };
    clusters.personal = {
      state = "active";
      network = {
        tailscale_tag = "tag:cluster-personal";
        intra_cluster = "mesh";
        storage.ports_tcp = [ ];
        egress.clusters = [ ];
      };
      access = {
        teams = [ ];
        users = [ ];
      };
    };
    machineAge = { };
    loginNodesOfCluster.personal = [ ];
    computeNodesOfCluster.personal = [ ];
    storageNodesOfCluster.personal = [ ];
    controllerNodesOfCluster.personal = [ ];
    users = {
      owner = {
        admin_scopes = [ "tailnet" ];
        archived = false;
        headscale_user = "owner";
        keys.age = [ ];
      };
      revoked = {
        admin_scopes = [ "tailnet" ];
        archived = true;
        headscale_user = "revoked";
        keys.age = [ ];
      };
    };
  };
  codegen = self.lib.mkCodegen {
    inherit inventory;
    inherit (pkgs) lib;
  };
  aclFile = "${codegen.headscaleAcl { inherit pkgs; }}/policy.hujson";
  adminInventory = inventory // {
    hosts = {
      admin-client = {
        state = "provisioned";
        topology_roles = [ "admin-client" ];
        monitoring = {
          enabled = true;
          exporters = [
            "node"
            "smartctl"
          ];
        };
      };
      controller = {
        state = "provisioned";
        topology_roles = [ "controller" ];
      };
    };
    controllerNodesOfCluster.personal = [ "controller" ];
  };
  adminCodegen = self.lib.mkCodegen {
    inventory = adminInventory;
    inherit (pkgs) lib;
  };
  adminAclFile = "${adminCodegen.headscaleAcl { inherit pkgs; }}/policy.hujson";
in
pkgs.testers.runNixOSTest {
  name = "headscale-codegen";

  nodes.headscale = testlib.mkHeadscaleNode { inherit aclFile; };

  testScript = ''
    start_all()
    ${testlib.snippets.bootHeadscale}

    import json

    def load_policy(path):
        raw = headscale.succeed(f"cat {path}")
        return json.loads("\n".join(
            line for line in raw.splitlines() if not line.startswith("//")
        ))

    policy = load_policy("${aclFile}")
    assert policy["groups"]["group:admin"] == ["owner@"], policy
    assert "revoked@" not in str(policy), policy
    assert any(
        "group:admin" in rule["src"] and "tag:cluster-personal:*" in rule["dst"]
        for rule in policy["acls"]
    ), policy

    headscale.succeed("headscale users create owner")
    headscale.succeed("headscale policy check --file ${aclFile}")

    admin_policy = load_policy("${adminAclFile}")
    assert admin_policy["tagOwners"]["tag:fleet-admin-client"] == ["group:admin"], admin_policy
    assert not any("group:admin" in rule["src"] for rule in admin_policy["acls"]), admin_policy
    assert any(
        "tag:fleet-admin-client" in rule["src"]
        and "tag:cluster-personal:*" in rule["dst"]
        and "tag:bootstrap:*" in rule["dst"]
        for rule in admin_policy["acls"]
    ), admin_policy
    assert admin_policy["tagOwners"]["tag:metrics"] == ["group:admin"], admin_policy
    assert any(
        "tag:cluster-personal-controller" in rule["src"]
        and sorted(rule["dst"]) == [
            "tag:metrics:9100",
            "tag:metrics:9633",
        ]
        for rule in admin_policy["acls"]
    ), admin_policy
    headscale.succeed("headscale policy check --file ${adminAclFile}")

    print("GENERATED HEADSCALE POLICY VERIFIED")
  '';
}
