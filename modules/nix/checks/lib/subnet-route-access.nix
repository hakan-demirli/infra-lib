{ pkgs, self }:
let
  inherit (pkgs) lib;
  testlib = import ./lib.nix { inherit pkgs; };
  types = import (self + "/modules/lib/types.nix") { inherit lib; };
  inventory = import (self + "/modules/lib/inventory.nix") {
    inherit lib types;
    self = ./fixtures/subnet-routes;
  };
  acl = (self.lib.mkCodegen { inherit lib inventory; }).headscaleAcl { inherit pkgs; };

  route = lib.head inventory.subnetRoutes.router;
  network = inventory.networks.${route.network};
  prefixLength = lib.toInt (lib.last (lib.splitString "/" network.prefix_v4));

  mkLaptop =
    { ... }:
    {
      imports = [ (testlib.mkTailscaleNode { }) ];
      environment.systemPackages = [ pkgs.netcat-openbsd ];
    };
in
pkgs.testers.runNixOSTest {
  name = "subnet-route-access";

  nodes = {
    headscale = {
      imports = [
        (testlib.mkHeadscaleNode { aclFile = "${acl}/policy.hujson"; })
        (self + "/modules/services/headscale-users.nix")
      ];
      services.headscale-users = {
        enable = true;
        usersFile = "${acl}/users";
      };
    };

    laptop_guest = mkLaptop;
    laptop_stranger = mkLaptop;

    lan_desk = {
      virtualisation.vlans = [ 2 ];
      networking = {
        interfaces.eth1.ipv4.addresses = lib.mkForce [
          {
            address = route.ipv4;
            inherit prefixLength;
          }
        ];
        firewall.allowedTCPPorts = [ 8080 ];
      };
      services.openssh.enable = true;
      systemd.services.decoy = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.netcat-openbsd}/bin/nc -lk 8080";
      };
    };

    router = {
      imports = [ (testlib.mkTailscaleNode { }) ];
      virtualisation.vlans = [
        1
        2
      ];
      networking.interfaces.eth2.ipv4.addresses = lib.mkForce [
        {
          address = network.gateway_v4;
          inherit prefixLength;
        }
      ];
      boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
      services.openssh.enable = true;
    };
  };

  testScript = ''
    start_all()
    ${testlib.snippets.bootHeadscale}
    ${testlib.snippets.helperDefs}

    headscale.succeed("headscale policy check --file ${acl}/policy.hujson")

    with subtest("the users that the policy names exist without manual steps"):
        headscale.wait_for_unit("headscale-users.service")
        names = [
            u.get("name")
            for u in json.loads(headscale.succeed("headscale users list --output json"))
        ]
        assert sorted(names) == ["guest", "owner"], names

    headscale.succeed("headscale users create stranger")

    router_key = headscale.succeed(
        "headscale preauthkeys create --expiration 1h --tags tag:cluster-router"
    ).strip()
    guest_key = headscale.succeed(
        f"headscale preauthkeys create --user {get_user_id('guest')} --expiration 1h"
    ).strip()
    stranger_key = headscale.succeed(
        f"headscale preauthkeys create --user {get_user_id('stranger')} --expiration 1h"
    ).strip()

    def join(node, hostname, key, flags):
        node.wait_for_unit("tailscaled.service")
        node.succeed(
            f"tailscale up --authkey={key} --hostname={hostname} "
            f"--login-server=https://headscale --timeout=60s {flags}"
        )

    join(router, "router", router_key, "--advertise-routes=${route.prefix}")

    with subtest("the policy approves the route of the router"):
        def route_approved(_):
            nodes = json.loads(headscale.succeed("headscale nodes list --output json"))
            node = next(n for n in nodes if (n.get("given_name") or n.get("name")) == "router")
            return node.get("approved_routes") == ["${route.prefix}"]
        retry(route_approved, timeout_seconds=60)

    join(laptop_guest, "laptop-guest", guest_key, "--accept-routes")
    join(laptop_stranger, "laptop-stranger", stranger_key, "--accept-routes")
    lan_desk.wait_for_unit("sshd.service")
    lan_desk.wait_for_unit("decoy.service")
    router_ip = router.succeed("tailscale ip -4").strip()

    with subtest("a team member reaches the granted port"):
        laptop_guest.wait_until_succeeds("nc -z -w 3 ${route.ipv4} 22", timeout=120)

    with subtest("a team member reaches no other port and no tailnet node"):
        laptop_guest.fail("nc -z -w 3 ${route.ipv4} 8080")
        laptop_guest.fail(f"nc -z -w 3 {router_ip} 22")

    with subtest("a user without a grant cannot reach the routed host"):
        laptop_stranger.fail("nc -z -w 3 ${route.ipv4} 22")

    print("SUBNET ROUTE ACCESS VERIFIED")
  '';
}
