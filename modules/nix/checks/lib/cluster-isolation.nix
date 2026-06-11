{
  pkgs,
  ...
}:
let
  testlib = import ./lib.nix { inherit pkgs; };

  aclFile = pkgs.writeText "cluster-isolation.hujson" (
    builtins.toJSON {
      groups = {
        "group:admin" = [ "owner@" ];
        "group:team-shared" = [ "shared-user@" ];
      };
      tagOwners = {
        "tag:cluster-priv-compute" = [ "group:admin" ];
        "tag:cluster-shared-compute" = [
          "group:admin"
          "group:team-shared"
        ];
      };
      acls = [
        {
          action = "accept";
          src = [ "group:admin" ];
          dst = [
            "tag:cluster-priv-compute:*"
            "tag:cluster-shared-compute:*"
          ];
        }
        {
          action = "accept";
          src = [ "group:team-shared" ];
          dst = [ "tag:cluster-shared-compute:*" ];
        }
        {
          action = "accept";
          src = [ "tag:cluster-priv-compute" ];
          dst = [ "tag:cluster-priv-compute:*" ];
        }
        {
          action = "accept";
          src = [ "tag:cluster-shared-compute" ];
          dst = [ "tag:cluster-shared-compute:*" ];
        }
      ];
    }
  );

  mkBareNode =
    { extraUpFlags }:
    { ... }:
    {
      imports = [ (testlib.mkTailscaleNode { inherit extraUpFlags; }) ];
      services.openssh.enable = true;
      virtualisation = {
        memorySize = 768;
        cores = 1;
      };
    };
in
pkgs.testers.runNixOSTest {
  name = "cluster-isolation";

  nodes = {
    headscale = testlib.mkHeadscaleNode { inherit aclFile; };

    priv_node1 = mkBareNode {
      extraUpFlags = [ "--advertise-tags=tag:cluster-priv-compute" ];
    };
    priv_node2 = mkBareNode {
      extraUpFlags = [ "--advertise-tags=tag:cluster-priv-compute" ];
    };
    shared_node1 = mkBareNode {
      extraUpFlags = [ "--advertise-tags=tag:cluster-shared-compute" ];
    };
    shared_node2 = mkBareNode {
      extraUpFlags = [ "--advertise-tags=tag:cluster-shared-compute" ];
    };

    owner_laptop = testlib.mkTailscaleNode { };
    shared_user_laptop = testlib.mkTailscaleNode { };
  };

  testScript = ''
    import time

    t0 = time.time()
    def stage(msg):
        elapsed = time.time() - t0
        print(f"\n========== [t+{elapsed:6.1f}s] {msg} ==========")

    def say(msg):
        elapsed = time.time() - t0
        print(f"[t+{elapsed:6.1f}s] {msg}")

    stage("start_all: booting 7 VMs")
    start_all()

    stage("wait for tailscaled on every node")
    for n, name in [
        (headscale, "headscale"),
        (priv_node1, "priv_node1"),
        (priv_node2, "priv_node2"),
        (shared_node1, "shared_node1"),
        (shared_node2, "shared_node2"),
        (owner_laptop, "owner_laptop"),
        (shared_user_laptop, "shared_user_laptop"),
    ]:
        say(f"waiting for network.target on {name}")
        n.wait_for_unit("network.target", timeout=120)
        say(f"network.target up on {name}")
    for n, name in [
        (priv_node1, "priv_node1"),
        (priv_node2, "priv_node2"),
        (shared_node1, "shared_node1"),
        (shared_node2, "shared_node2"),
        (owner_laptop, "owner_laptop"),
        (shared_user_laptop, "shared_user_laptop"),
    ]:
        say(f"waiting for tailscaled.service on {name}")
        n.wait_for_unit("tailscaled.service", timeout=120)
        say(f"tailscaled.service up on {name}")

    stage("boot headscale + nginx + DERP")
    headscale.wait_for_unit("headscale.service", timeout=120)
    say("headscale.service up")
    headscale.wait_for_unit("nginx.service", timeout=60)
    say("nginx.service up")
    headscale.wait_for_open_port(8080, timeout=60)
    say("headscale listening on 8080")
    headscale.wait_for_open_port(443, timeout=60)
    say("nginx listening on 443")

    stage("create headscale users")
    headscale.succeed("headscale users create owner")
    say("created user 'owner'")
    headscale.succeed("headscale users create shared-user")
    say("created user 'shared-user'")

    import json
    def get_user_id(username):
        out = headscale.succeed("headscale users list --output json")
        for u in json.loads(out):
            if u.get("name") == username:
                return u["id"]
        raise Exception(f"user {username!r} not found in {out}")

    owner_id = get_user_id("owner")
    shared_user_id = get_user_id("shared-user")
    say(f"owner_id={owner_id} shared_user_id={shared_user_id}")

    stage("issue preauth keys")
    priv_key = headscale.succeed(
        "headscale preauthkeys create --reusable --expiration 24h "
        "--tags tag:cluster-priv-compute"
    ).strip()
    say("got priv compute preauth key")
    shared_key = headscale.succeed(
        "headscale preauthkeys create --reusable --expiration 24h "
        "--tags tag:cluster-shared-compute"
    ).strip()
    say("got shared compute preauth key")
    owner_key = headscale.succeed(
        f"headscale preauthkeys create --user {owner_id} --reusable --expiration 24h"
    ).strip()
    say("got owner laptop preauth key")
    shared_user_key = headscale.succeed(
        f"headscale preauthkeys create --user {shared_user_id} --reusable --expiration 24h"
    ).strip()
    say("got shared-user laptop preauth key")

    stage("join nodes to tailnet")
    def join(node, hostname, key):
        say(f"joining {hostname}")
        node.succeed(
            f"tailscale up --authkey={key} --hostname={hostname} "
            f"--login-server=https://headscale --timeout=60s"
        )
        node.wait_until_succeeds(
            f"tailscale status | grep -E '\\b{hostname}\\b' >&2",
            timeout=60,
        )
        say(f"{hostname} appears in its own tailscale status")
        headscale.wait_until_succeeds(
            f"headscale nodes list | grep -F {hostname}",
            timeout=60,
        )
        say(f"headscale sees node {hostname}")

    join(priv_node1, "priv-node1", priv_key)
    join(priv_node2, "priv-node2", priv_key)
    join(shared_node1, "shared-node1", shared_key)
    join(shared_node2, "shared-node2", shared_key)
    join(owner_laptop, "owner-laptop", owner_key)
    join(shared_user_laptop, "shared-user-laptop", shared_user_key)

    stage("resolve tailnet IPs")
    def get_ts_ip(node, name):
        ip = node.wait_until_succeeds(
            "tailscale ip -4 | head -n1",
            timeout=60,
        ).strip()
        say(f"{name} tailnet IP: {ip}")
        return ip

    priv1_ip = get_ts_ip(priv_node1, "priv_node1")
    priv2_ip = get_ts_ip(priv_node2, "priv_node2")
    shared1_ip = get_ts_ip(shared_node1, "shared_node1")
    shared2_ip = get_ts_ip(shared_node2, "shared_node2")
    owner_ip = get_ts_ip(owner_laptop, "owner_laptop")
    user_ip = get_ts_ip(shared_user_laptop, "shared_user_laptop")

    stage("INVARIANT 1: owner -> priv nodes")
    with subtest("owner reaches priv-node1"):
        owner_laptop.wait_until_succeeds(f"ping -c 2 -W 4 {priv1_ip}", timeout=60)
        say("OK owner -> priv-node1")
    with subtest("owner reaches priv-node2"):
        owner_laptop.wait_until_succeeds(f"ping -c 2 -W 4 {priv2_ip}", timeout=60)
        say("OK owner -> priv-node2")

    stage("INVARIANT 2: shared-user -> shared nodes")
    with subtest("shared-user reaches shared-node1"):
        shared_user_laptop.wait_until_succeeds(f"ping -c 2 -W 4 {shared1_ip}", timeout=60)
        say("OK shared-user -> shared-node1")
    with subtest("shared-user reaches shared-node2"):
        shared_user_laptop.wait_until_succeeds(f"ping -c 2 -W 4 {shared2_ip}", timeout=60)
        say("OK shared-user -> shared-node2")

    stage("INVARIANT 3: shared-user blocked from priv nodes")
    with subtest("shared-user cannot ping priv-node1"):
        shared_user_laptop.fail(f"ping -c 2 -W 2 {priv1_ip}")
        say("OK shared-user blocked from priv-node1")
    with subtest("shared-user cannot ping priv-node2"):
        shared_user_laptop.fail(f"ping -c 2 -W 2 {priv2_ip}")
        say("OK shared-user blocked from priv-node2")

    stage("INVARIANT 4: priv-compute <-/-> shared-compute")
    with subtest("priv-node1 cannot ping shared-node1"):
        priv_node1.fail(f"ping -c 2 -W 2 {shared1_ip}")
        say("OK priv-node1 blocked from shared-node1")
    with subtest("priv-node1 cannot ping shared-node2"):
        priv_node1.fail(f"ping -c 2 -W 2 {shared2_ip}")
        say("OK priv-node1 blocked from shared-node2")
    with subtest("shared-node1 cannot ping priv-node1"):
        shared_node1.fail(f"ping -c 2 -W 2 {priv1_ip}")
        say("OK shared-node1 blocked from priv-node1")
    with subtest("shared-node1 cannot ping priv-node2"):
        shared_node1.fail(f"ping -c 2 -W 2 {priv2_ip}")
        say("OK shared-node1 blocked from priv-node2")

    stage(f"DONE in {time.time() - t0:.1f}s")
    print("CLUSTER ISOLATION VERIFICATIONS PASSED")
  '';
}
