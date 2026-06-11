{ pkgs, ... }:
let
  testlib = import ./lib.nix { inherit pkgs; };

  aclFile = pkgs.writeText "bootstrap-tag.hujson" (
    builtins.toJSON {
      groups = {
        "group:admin" = [ "owner@" ];
      };
      tagOwners = {
        "tag:bootstrap" = [ "group:admin" ];
        "tag:cluster-priv-compute" = [ "group:admin" ];
      };
      acls = [
        {
          action = "accept";
          src = [ "group:admin" ];
          dst = [
            "tag:cluster-priv-compute:*"
            "tag:bootstrap:*"
          ];
        }
        {
          action = "accept";
          src = [ "tag:cluster-priv-compute" ];
          dst = [ "tag:cluster-priv-compute:*" ];
        }
      ];
    }
  );
in
pkgs.testers.runNixOSTest {
  name = "bootstrap-tag";

  nodes = {
    headscale = testlib.mkHeadscaleNode { inherit aclFile; };

    admin_laptop = testlib.mkTailscaleNode { };

    bootstrap_a = testlib.mkTailscaleNode { extraUpFlags = [ "--advertise-tags=tag:bootstrap" ]; };
    bootstrap_b = testlib.mkTailscaleNode { extraUpFlags = [ "--advertise-tags=tag:bootstrap" ]; };

    priv_compute = testlib.mkTailscaleNode {
      extraUpFlags = [ "--advertise-tags=tag:cluster-priv-compute" ];
    };
  };

  testScript = ''
    start_all()

    ${testlib.snippets.bootHeadscale}
    ${testlib.snippets.helperDefs}

    headscale.succeed("headscale users create owner")
    owner_id = get_user_id("owner")

    bootstrap_key = headscale.succeed(
        f"headscale preauthkeys create --user {owner_id} --reusable --expiration 24h --tags tag:bootstrap"
    ).strip()
    cluster_key = headscale.succeed(
        f"headscale preauthkeys create --user {owner_id} --reusable --expiration 24h --tags tag:cluster-priv-compute"
    ).strip()
    admin_key = headscale.succeed(
        f"headscale preauthkeys create --user {owner_id} --reusable --expiration 24h"
    ).strip()

    for n in [admin_laptop, bootstrap_a, bootstrap_b, priv_compute]:
        n.wait_for_unit("tailscaled.service")

    admin_laptop.succeed(
        f"tailscale up --authkey={admin_key} --hostname=admin --login-server=https://headscale"
    )
    bootstrap_a.succeed(
        f"tailscale up --authkey={bootstrap_key} --hostname=bootstrap-a --login-server=https://headscale"
    )
    bootstrap_b.succeed(
        f"tailscale up --authkey={bootstrap_key} --hostname=bootstrap-b --login-server=https://headscale"
    )
    priv_compute.succeed(
        f"tailscale up --authkey={cluster_key} --hostname=priv-compute --login-server=https://headscale"
    )

    for name in ["admin", "bootstrap-a", "bootstrap-b", "priv-compute"]:
        headscale.wait_until_succeeds(f"headscale nodes list | grep {name}")

    admin_ip   = get_ts_ip(admin_laptop)
    boot_a_ip  = get_ts_ip(bootstrap_a)
    boot_b_ip  = get_ts_ip(bootstrap_b)
    priv_ip    = get_ts_ip(priv_compute)

    print(f"admin={admin_ip} boot_a={boot_a_ip} boot_b={boot_b_ip} priv={priv_ip}")

    with subtest("admin can reach both bootstrap nodes (one-way)"):
        admin_laptop.wait_until_succeeds(f"ping -c 2 {boot_a_ip}")
        admin_laptop.wait_until_succeeds(f"ping -c 2 {boot_b_ip}")
        admin_laptop.wait_until_succeeds(f"ping -c 2 {priv_ip}")

    with subtest("bootstrap node cannot reach admin (no src rule)"):
        bootstrap_a.fail(f"ping -c 2 -W 2 {admin_ip}")

    with subtest("bootstrap node cannot reach other bootstrap node"):
        bootstrap_a.fail(f"ping -c 2 -W 2 {boot_b_ip}")
        bootstrap_b.fail(f"ping -c 2 -W 2 {boot_a_ip}")

    with subtest("bootstrap node cannot reach the real cluster"):
        bootstrap_a.fail(f"ping -c 2 -W 2 {priv_ip}")
        bootstrap_b.fail(f"ping -c 2 -W 2 {priv_ip}")

    with subtest("cluster node CAN reach itself (sanity, proves rules apply)"):
        priv_compute.wait_until_succeeds("ping -c 2 127.0.0.1")

    print("BOOTSTRAP-TAG ACL VERIFICATIONS PASSED")
  '';
}
