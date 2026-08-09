{ pkgs, self }:
let
  testlib = import ./lib.nix { inherit pkgs; };
  inventory = {
    hosts = { };
    deploymentRoles = { };
    networks = { };
    activeDeploymentRoles = [ ];
    teams = { };
    clusters = { };
    machineAge = { };
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
in
pkgs.testers.runNixOSTest {
  name = "headscale-codegen";

  nodes.headscale = testlib.mkHeadscaleNode { inherit aclFile; };

  testScript = ''
    start_all()
    ${testlib.snippets.bootHeadscale}

    policy = headscale.succeed("cat ${aclFile}")
    assert '\"group:admin\":[\"owner@\"]' in policy, policy
    assert "revoked@" not in policy, policy

    headscale.succeed("headscale users create owner")
    headscale.succeed("headscale policy check --file ${aclFile}")

    print("GENERATED HEADSCALE POLICY VERIFIED")
  '';
}
