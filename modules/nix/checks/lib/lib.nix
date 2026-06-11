{ pkgs }:
let
  inherit (pkgs) lib;
in
rec {
  headscaleIp = "192.168.1.1";

  tlsCert = pkgs.runCommand "selfSignedCerts" { buildInputs = [ pkgs.openssl ]; } ''
    openssl req \
      -x509 -newkey rsa:4096 -sha256 -days 365 \
      -nodes -out cert.pem -keyout key.pem \
      -subj '/CN=headscale' -addext "subjectAltName=DNS:headscale"
    mkdir -p $out
    cp key.pem cert.pem $out
  '';

  derpMap = pkgs.writeText "derp.yaml" ''
    regions:
      900:
        regionid: 900
        regioncode: "test"
        regionname: "Test Region"
        nodes:
          - name: "900a"
            regionid: 900
            hostname: "headscale"
            ipv4: "${headscaleIp}"
            stunport: 3478
            derpport: 443
  '';

  mkHeadscaleNode =
    { aclFile }:
    { pkgs, ... }:
    {
      services = {
        headscale = {
          enable = true;
          settings = {
            server_url = "https://headscale";
            listen_addr = "127.0.0.1:8080";
            ip_prefixes = [ "100.64.0.0/10" ];
            policy.path = aclFile;
            dns = {
              magic_dns = true;
              base_domain = "ts.cluster.local";
              nameservers.global = [ "1.1.1.1" ];
            };
            derp = {
              server = {
                enable = true;
                region_code = "test";
                region_id = 900;
                private_key_path = "/var/lib/headscale/derp.key";
                stun_listen_addr = "0.0.0.0:3478";
              };
              urls = [ ];
              paths = [ derpMap ];
            };
          };
        };

        nginx = {
          enable = true;
          virtualHosts.headscale = {
            addSSL = true;
            sslCertificate = "${tlsCert}/cert.pem";
            sslCertificateKey = "${tlsCert}/key.pem";
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
        };
      };

      networking.firewall = {
        enable = true;
        allowedTCPPorts = [
          80
          443
        ];
        allowedUDPPorts = [ 3478 ];
      };

      environment.systemPackages = [ pkgs.headscale ];
    };

  mkTailscaleNode =
    {
      extraUpFlags ? [ ],
      sshEnabled ? false,
    }:
    { config, ... }:
    {
      services.tailscale = {
        enable = true;
        port = 41641;
        extraUpFlags = [
          "--login-server=https://headscale"
        ]
        ++ extraUpFlags
        ++ lib.optional sshEnabled "--ssh";
      };

      systemd.services.tailscaled = {
        environment = {
          TS_NO_UDP_GROT = "1";
          TS_DEBUG_NETCHECK = "0";
        };
        serviceConfig.LogLevelMax = "notice";
      };

      security.pki.certificateFiles = [ "${tlsCert}/cert.pem" ];

      networking = {
        firewall = {
          enable = true;
          allowedUDPPorts = [ config.services.tailscale.port ];
          checkReversePath = "loose";
          trustedInterfaces = [ "tailscale0" ];
        };
        extraHosts = "${headscaleIp} headscale";
      };
    };

  snippets = {
    bootHeadscale = ''
      headscale.wait_for_unit("headscale.service")
      headscale.wait_for_open_port(8080)
      headscale.wait_for_open_port(443)
    '';

    helperDefs = ''
      import json

      def get_user_id(username):
          output = headscale.succeed("headscale users list --output json")
          for u in json.loads(output):
              if u.get("name") == username:
                  return u["id"]
          raise Exception(f"User {username!r} not found")

      def get_ts_ip(node):
          return node.succeed("tailscale ip -4").strip()
    '';
  };

  mkSlurmInventory =
    { masterHostname, clusterNodes }:
    let
      hosts = lib.listToAttrs (
        map (node: {
          name = node.hostName;
          value = {
            id = node.hostName;
            hardware = {
              cpu_sockets = node.sockets;
              cpu_cores_per_socket = node.coresPerSocket;
              cpu_threads_per_core = node.threadsPerCore;
              cpu_logical_count = node.cpuLogicalCount or null;
              ram_mib = node.ramMb;
            };
            slurm_features = node.features or [ ];
            slurm_gres = node.gres or [ ];
            slurm_weight = node.weight or 100;
          };
        }) clusterNodes
      );
      nodeIds = map (node: node.hostName) clusterNodes;
    in
    {
      inherit hosts;
      hostToCluster = lib.genAttrs nodeIds (_: "test-cluster");
      clusters.test-cluster = {
        id = "test-cluster";
        scheduler = {
          kind = "slurm";
          controllers = [ masterHostname ];
          partitions.compute = {
            nodes = lib.filter (name: name != masterHostname) nodeIds;
            default = true;
            max_time = "INFINITE";
            gres = null;
          };
        };
      };
    };

  mkSlurmMaster =
    { hostName, clusterNodes }:
    { lib, ... }:
    let
      inventory = mkSlurmInventory {
        masterHostname = hostName;
        inherit clusterNodes;
      };
    in
    {
      imports = [ ../../../services/slurm.nix ];
      _module.args = {
        host = inventory.hosts.${hostName};
        cluster = inventory;
      };
      networking.hostName = lib.mkForce hostName;
      networking.firewall.enable = lib.mkForce false;
      services = {
        slurm-cluster = {
          enable = true;
          allowInsecureTestKey = true;
        };
        timesyncd.enable = lib.mkForce false;
        openssh.enable = true;
        slurm.extraConfig = lib.mkAfter ''
          SlurmdParameters=config_overrides
          ReturnToService=2
        '';
      };
      virtualisation = {
        memorySize = 2048;
        cores = 2;
      };
    };

  mkSlurmCompute =
    {
      hostName,
      masterHostname,
      clusterNodes,
      adopt ? true,
    }:
    { lib, ... }:
    let
      inventory = mkSlurmInventory { inherit masterHostname clusterNodes; };
    in
    {
      imports = [ ../../../services/slurm.nix ];
      _module.args = {
        host = inventory.hosts.${hostName};
        cluster = inventory;
      };
      networking.hostName = lib.mkForce hostName;
      networking.firewall.enable = lib.mkForce false;
      services = {
        slurm-cluster = {
          enable = true;
          allowInsecureTestKey = true;
          adoptSshSessions = adopt;
        };
        timesyncd.enable = lib.mkForce false;
        openssh.enable = true;
      };
      virtualisation = {
        memorySize = 1536;
        cores = 2;
      };
    };

  mkSlurmSubmit =
    {
      hostName,
      masterHostname,
      clusterHosts ? "",
    }:
    { lib, ... }:
    let
      inventory = {
        hosts = {
          ${hostName}.id = hostName;
          ${masterHostname}.id = masterHostname;
          compute.id = "compute";
        };
        hostToCluster.${hostName} = "test-cluster";
        clusters.test-cluster = {
          id = "test-cluster";
          scheduler = {
            kind = "slurm";
            controllers = [ masterHostname ];
            partitions.compute.nodes = [ "compute" ];
          };
        };
      };
    in
    {
      imports = [ ../../../services/slurm-client.nix ];
      _module.args = {
        host = inventory.hosts.${hostName};
        cluster = inventory;
      };
      networking = {
        hostName = lib.mkForce hostName;
        firewall.enable = lib.mkForce false;
        extraHosts = clusterHosts;
      };
      services = {
        slurm-client = {
          enable = true;
          allowInsecureTestKey = true;
        };
        timesyncd.enable = lib.mkForce false;
        openssh.enable = true;
      };
      virtualisation = {
        memorySize = 1024;
        cores = 1;
      };
    };
}
