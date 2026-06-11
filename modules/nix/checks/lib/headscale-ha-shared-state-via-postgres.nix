{
  pkgs,
  ...
}:
let
  ha = import ./lib/headscale-ha-cluster.nix {
    inherit pkgs;
    inherit (pkgs) lib;
  };
in
pkgs.testers.runNixOSTest {
  name = "headscale-ha-shared-state-via-postgres";

  nodes = {
    pg_node = ha.pgNode;
    headscale_a = ha.mkHeadscaleHaNode {
      ip = ha.cfg.headscaleAIp;
      hostname = "headscale-a";
    };
    headscale_b = ha.mkHeadscaleHaNode {
      ip = ha.cfg.headscaleBIp;
      hostname = "headscale-b";
    };
  };

  testScript = ''
    ${ha.bootstrapMinimal}

    with subtest("testuser created on headscale_a is visible on headscale_b"):
        users_b = json.loads(headscale_b.succeed("headscale users list --output json"))
        assert any(u.get("name") == "testuser" for u in users_b), (
            "headscale_b does NOT see testuser created via headscale_a. "
            "The shared postgres backend is not working: each headscale "
            "would have its own private view of the world."
        )
        print("INVARIANT HELD: user created on headscale_a visible on "
              "headscale_b (shared postgres backend works)")
  '';
}
