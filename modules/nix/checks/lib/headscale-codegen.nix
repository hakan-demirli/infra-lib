{ pkgs, self }:
let
  testlib = import ./lib.nix { inherit pkgs; };
  inventory = {
    hosts = { };
    roles = { };
    networks = { };
    activeRoles = { };
    teams = { };
    clusters = { };
    machineAge = { };
    users.owner = {
      cohort = "admin";
      headscale_user = "owner";
      keys.age = [ ];
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

    headscale.succeed("headscale users create owner")
    headscale.succeed("headscale policy check --file ${aclFile}")

    print("GENERATED HEADSCALE POLICY VERIFIED")
  '';
}
