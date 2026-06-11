{ pkgs, lib }:
let
  testlib = import ../lib.nix { inherit pkgs; };

  cfg = {
    pgIp = "192.168.1.20";
    headscaleAIp = "192.168.1.21";
    headscaleBIp = "192.168.1.22";
    client1Ip = "192.168.1.30";
    client2Ip = "192.168.1.31";
    client3Ip = "192.168.1.32";
    pgDbName = "headscale";
    pgUser = "headscale";
    pgPassword = "headscale-test-password-not-secret";
  };

  aclFile = pkgs.writeText "headscale-ha.hujson" (
    builtins.toJSON {
      groups = {
        "group:mesh" = [ "testuser@" ];
      };
      tagOwners = { };
      acls = [
        {
          action = "accept";
          src = [ "group:mesh" ];
          dst = [ "group:mesh:*" ];
        }
      ];
    }
  );

  mkHeadscaleSettings = _nodeIp: {
    server_url = "https://headscale-a";
    listen_addr = "0.0.0.0:8080";
    metrics_listen_addr = "127.0.0.1:9090";
    grpc_listen_addr = "127.0.0.1:50443";
    private_key_path = "/var/lib/headscale/private.key";
    noise.private_key_path = "/var/lib/headscale/noise_private.key";
    derp = {
      server = {
        enabled = true;
        region_id = 900;
        region_code = "test";
        region_name = "Test Region";
        stun_listen_addr = "0.0.0.0:3478";
      };
      urls = [ ];
      paths = [ testlib.derpMap ];
    };
    database = {
      type = "postgres";
      postgres = {
        host = cfg.pgIp;
        port = 5432;
        name = cfg.pgDbName;
        user = cfg.pgUser;
        password = cfg.pgPassword;
      };
    };
    policy = {
      mode = "file";
      path = "${aclFile}";
    };
    dns = {
      magic_dns = false;
      base_domain = "ha.test";
      nameservers.global = [ ];
      search_domains = [ ];
      override_local_dns = false;
    };
  };

  pgNode = _: {
    virtualisation = {
      vlans = [ 1 ];
      memorySize = 1024;
      cores = 1;
    };
    networking = {
      dhcpcd.enable = false;
      interfaces.eth1.ipv4.addresses = lib.mkOverride 0 [
        {
          address = cfg.pgIp;
          prefixLength = 24;
        }
      ];
      firewall = {
        enable = true;
        allowedTCPPorts = [ 5432 ];
      };
    };
    services.postgresql = {
      enable = true;
      enableTCPIP = true;
      ensureDatabases = [ cfg.pgDbName ];
      ensureUsers = [
        {
          name = cfg.pgUser;
          ensureDBOwnership = true;
        }
      ];
      authentication = lib.mkForce ''
        local all all              trust
        host  all all 127.0.0.1/32 trust
        host  all all ::1/128      trust
        host  all all 192.168.1.0/24 trust
      '';
    };
  };

  mkHeadscaleHaNode =
    { ip, hostname }:
    { pkgs, ... }:
    {
      virtualisation = {
        vlans = [ 1 ];
        memorySize = 1024;
        cores = 1;
      };
      networking = {
        hostName = lib.mkForce hostname;
        dhcpcd.enable = false;
        interfaces.eth1.ipv4.addresses = lib.mkOverride 0 [
          {
            address = ip;
            prefixLength = 24;
          }
        ];
        firewall = {
          enable = true;
          allowedTCPPorts = [
            80
            443
          ];
          allowedUDPPorts = [ 3478 ];
        };
        extraHosts = ''
          ${cfg.pgIp} pg-node
          ${cfg.headscaleAIp} headscale-a
          ${cfg.headscaleBIp} headscale-b
        '';
      };
      services.headscale = {
        enable = true;
        settings = mkHeadscaleSettings ip;
      };
      services.nginx = {
        enable = true;
        virtualHosts."headscale-a" = lib.mkIf (hostname == "headscale-a") {
          addSSL = true;
          sslCertificate = "${testlib.tlsCert}/cert.pem";
          sslCertificateKey = "${testlib.tlsCert}/key.pem";
          locations."/" = {
            proxyPass = "http://127.0.0.1:8080";
            proxyWebsockets = true;
            extraConfig = ''
              proxy_read_timeout 600s;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "upgrade";
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
            '';
          };
        };
        virtualHosts."headscale-b" = lib.mkIf (hostname == "headscale-b") {
          addSSL = true;
          sslCertificate = "${testlib.tlsCert}/cert.pem";
          sslCertificateKey = "${testlib.tlsCert}/key.pem";
          locations."/" = {
            proxyPass = "http://127.0.0.1:8080";
            proxyWebsockets = true;
            extraConfig = ''
              proxy_read_timeout 600s;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "upgrade";
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
            '';
          };
        };
      };
      systemd.services.headscale = {
        after = [
          "network-online.target"
          "nss-lookup.target"
        ];
        wants = [
          "network-online.target"
        ];
      };
      environment.systemPackages = [ pkgs.headscale ];
    };

  mkClientNode =
    ip:
    { config, ... }:
    {
      virtualisation = {
        vlans = [ 1 ];
        memorySize = 768;
        cores = 1;
      };
      networking = {
        dhcpcd.enable = false;
        interfaces.eth1.ipv4.addresses = lib.mkOverride 0 [
          {
            address = ip;
            prefixLength = 24;
          }
        ];
        firewall = {
          enable = true;
          allowedUDPPorts = [ config.services.tailscale.port ];
          checkReversePath = "loose";
          trustedInterfaces = [ "tailscale0" ];
        };
        extraHosts = ''
          ${cfg.pgIp} pg-node
          ${cfg.headscaleAIp} headscale-a
          ${cfg.headscaleBIp} headscale-b
        '';
      };
      services.tailscale = {
        enable = true;
        port = 41641;
      };
      systemd.services.tailscaled = {
        environment = {
          TS_NO_UDP_GROT = "1";
          TS_DEBUG_NETCHECK = "0";
        };
        serviceConfig.LogLevelMax = "notice";
      };
      security.pki.certificateFiles = [ "${testlib.tlsCert}/cert.pem" ];
    };

  bootstrapMinimal = ''
    import json

    start_all()

    with subtest("[ha fixture] postgres + both headscales up"):
        pg_node.wait_for_unit("postgresql.service")
        pg_node.wait_for_open_port(5432)
        for hs in (headscale_a, headscale_b):
            hs.wait_for_unit("headscale.service", timeout=180)
            hs.wait_for_open_port(8080, timeout=120)
            hs.wait_for_open_port(443, timeout=60)

    with subtest("[ha fixture] create user + preauth key on headscale_a"):
        headscale_a.succeed("headscale users create testuser")
        users_out = headscale_a.succeed("headscale users list --output json")
        user_id = next(
            (u["id"] for u in json.loads(users_out) if u.get("name") == "testuser"),
            None,
        )
        assert user_id is not None, "testuser not found after create"
        auth_key_out = headscale_a.succeed(
            f"headscale --user {user_id} preauthkeys create "
            f"--reusable --expiration 24h --output json"
        )
        auth_key = json.loads(auth_key_out)["key"]
  '';

  bootstrapWithClients = ''
    ${bootstrapMinimal}

    with subtest("[ha fixture] register 3 clients via headscale_a"):
        for c in (client_1, client_2, client_3):
            c.wait_for_unit("tailscaled.service")
            c.succeed(
                f"tailscale up "
                f"--login-server=https://headscale-a "
                f"--authkey={auth_key}"
            )
        headscale_a.wait_until_succeeds(
            "test $(headscale nodes list --output json | "
            "python3 -c 'import sys,json; print(sum(1 for n in json.load(sys.stdin) if n.get(\"online\")))') -eq 3",
            timeout=300,
        )

    with subtest("[ha fixture] tailnet IPs + 3-node mesh forms"):
        c1_ip = client_1.succeed("tailscale ip -4").strip()
        c2_ip = client_2.succeed("tailscale ip -4").strip()
        c3_ip = client_3.succeed("tailscale ip -4").strip()
        for src, dst in (
            (client_1, c2_ip),
            (client_2, c3_ip),
            (client_3, c1_ip),
        ):
            src.wait_until_succeeds(f"ping -c 2 -W 5 {dst}", timeout=180)
  '';

in
{
  inherit
    cfg
    pgNode
    mkHeadscaleHaNode
    mkClientNode
    bootstrapMinimal
    bootstrapWithClients
    ;
}
