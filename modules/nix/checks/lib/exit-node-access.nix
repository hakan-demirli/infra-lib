{
  pkgs,
  self,
  inputs,
}:
let
  inherit (pkgs) lib;
  testlib = import ./lib.nix { inherit pkgs; };
  types = import (self + "/modules/lib/types.nix") { inherit lib; };
  inventory = import (self + "/modules/lib/inventory.nix") {
    inherit lib types;
    self = ./fixtures/exit-nodes;
  };
  acl = (self.lib.mkCodegen { inherit lib inventory; }).headscaleAcl { inherit pkgs; };
  # autogroup:internet excludes private ranges and an exit node refuses its own
  # on-link networks, so the public uplink address sits one hop behind a LAN.
  uplinkAddress = "203.0.113.20";
  uplinkLanAddress = "192.168.2.20";

  mkTailnetNode =
    host:
    { ... }:
    {
      imports = [
        inputs.impermanence.nixosModules.impermanence
        inputs.sops-nix.nixosModules.sops
        (self + "/modules/services/tailscale.nix")
      ];
      _module.args.host = host;
      services.tailscale = {
        loginServerHost = "headscale";
        useAuthKey = false;
        authKeyFile = "/run/keys/tailscale";
      };
      security.pki.certificateFiles = [ "${testlib.tlsCert}/cert.pem" ];
      networking.extraHosts = "${testlib.headscaleIp} headscale";
      environment.systemPackages = [ pkgs.netcat-openbsd ];
    };
in
assert inventory.tailnetExitNodes == [ "vps" ];
pkgs.testers.runNixOSTest {
  name = "exit-node-access";

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

    laptop_admin = mkTailnetNode inventory.hosts.laptop-admin;
    laptop_stranger = mkTailnetNode null;

    uplink = {
      virtualisation.vlans = [ 2 ];
      networking = {
        interfaces.eth1.ipv4.addresses = lib.mkForce [
          {
            address = uplinkLanAddress;
            prefixLength = 24;
          }
          {
            address = uplinkAddress;
            prefixLength = 32;
          }
        ];
        firewall.allowedTCPPorts = [ 8080 ];
      };
      systemd.services.uplink = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.netcat-openbsd}/bin/nc -lk 8080";
      };
    };

    vps = {
      imports = [ (mkTailnetNode inventory.hosts.vps) ];
      virtualisation.vlans = [
        1
        2
      ];
      networking.interfaces.eth2.ipv4.routes = [
        {
          address = uplinkAddress;
          prefixLength = 32;
          via = uplinkLanAddress;
        }
      ];
    };
  };

  testScript = ''
    start_all()
    ${testlib.snippets.bootHeadscale}
    ${testlib.snippets.helperDefs}

    headscale.succeed("headscale policy check --file ${acl}/policy.hujson")
    headscale.wait_for_unit("headscale-users.service")
    headscale.succeed("headscale users create stranger")
    uplink.wait_for_unit("uplink.service")

    with subtest("tailscale set declares the exit node before the node logs in"):
        for node in [vps, laptop_admin]:
            node.wait_until_succeeds(
                "test \"$(systemctl show -P ExecMainStartTimestampMonotonic tailscaled-set.service)\" != 0"
            )
            node.succeed("test \"$(systemctl show -P Result tailscaled-set.service)\" = success")
        vps.succeed("tailscale debug prefs | grep -F 0.0.0.0/0")
        laptop_admin.fail("tailscale debug prefs | grep -F 0.0.0.0/0")

    def join(node, key):
        node.succeed(f"install -d -m 0700 /run/keys && printf %s {key} > /run/keys/tailscale")
        node.succeed("systemctl restart tailscaled.service")
        node.wait_until_succeeds("tailscale ip -4", timeout=90)

    exit_key = headscale.succeed(
        "headscale preauthkeys create --expiration 1h --tags tag:exit-node"
    ).strip()
    admin_key = headscale.succeed(
        "headscale preauthkeys create --expiration 1h --tags tag:fleet-admin-client"
    ).strip()
    stranger_key = headscale.succeed(
        f"headscale preauthkeys create --user {get_user_id('stranger')} --expiration 1h"
    ).strip()

    join(vps, exit_key)
    join(laptop_admin, admin_key)
    join(laptop_stranger, stranger_key)
    vps_ip = get_ts_ip(vps)

    with subtest("the policy approves the exit routes of the tagged node"):
        def exit_routes_approved(_):
            nodes = json.loads(headscale.succeed("headscale nodes list --output json"))
            node = next(n for n in nodes if vps_ip in n.get("ip_addresses", []))
            return sorted(node.get("approved_routes") or []) == ["0.0.0.0/0", "::/0"]
        retry(exit_routes_approved, timeout_seconds=60)

    with subtest("an admin client reaches the internet only through the exit node"):
        laptop_admin.wait_until_succeeds(f"tailscale exit-node list | grep -F {vps_ip}", timeout=60)
        laptop_admin.fail("nc -z -w 3 ${uplinkAddress} 8080")
        laptop_admin.succeed(f"tailscale set --exit-node={vps_ip}")
        laptop_admin.wait_until_succeeds("nc -z -w 3 ${uplinkAddress} 8080", timeout=60)
        laptop_admin.succeed("tailscale set --exit-node=")
        laptop_admin.wait_until_fails("nc -z -w 3 ${uplinkAddress} 8080", timeout=60)

    with subtest("a client without the admin tag cannot use the exit node"):
        laptop_stranger.fail(f"tailscale exit-node list | grep -F {vps_ip}")
        laptop_stranger.execute(f"tailscale set --exit-node={vps_ip}")
        laptop_stranger.fail("nc -z -w 3 ${uplinkAddress} 8080")

    print("EXIT NODE ACCESS VERIFIED")
  '';
}
