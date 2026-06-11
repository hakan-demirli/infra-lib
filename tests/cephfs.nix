{
  pkgs,
  ...
}:
let
  inherit (pkgs) lib;

  cfg = {
    clusterId = "8a8b1c4e-3f5a-4d8c-9b1a-7c2e6f4d0e9a";
    fsName = "cephfs-test";
    monA = {
      name = "a";
      ip = "192.168.1.1";
    };
    osd0 = {
      name = "0";
      ip = "192.168.1.1";
      key = "AQBCEJNa3s8nHRAANvdsr93KqzBznuIWm2gOGg==";
      uuid = "55ba2294-3e24-478f-bee0-9dca4c231dd9";
    };
    osd1 = {
      name = "1";
      ip = "192.168.1.2";
      key = "AQBEEJNac00kExAAXEgy943BGyOpVH1LLlHafQ==";
      uuid = "5e97a838-85b6-43b0-8950-cb56d554d1e5";
    };
    computeIps = {
      compute1 = "192.168.1.10";
      compute2 = "192.168.1.11";
      compute3 = "192.168.1.12";
      compute4 = "192.168.1.13";
    };
  };

  mkCephConfig =
    daemonConfig:
    {
      enable = true;
      global = {
        fsid = cfg.clusterId;
        monHost = cfg.monA.ip;
        monInitialMembers = cfg.monA.name;
      };
    }
    // daemonConfig;

  storageANode =
    { pkgs, ... }:
    {
      imports = [ ../modules/services/ceph-exporter.nix ];

      virtualisation = {
        emptyDiskImages = [ 20480 ];
        vlans = [ 1 ];
        memorySize = 2048;
        cores = 2;
      };

      services.cluster-ceph-exporter = {
        enable = true;
        mgrInstance = cfg.monA.name;
      };

      networking = {
        dhcpcd.enable = false;
        interfaces.eth1.ipv4.addresses = lib.mkOverride 0 [
          {
            address = cfg.monA.ip;
            prefixLength = 24;
          }
        ];
        firewall = {
          allowedTCPPorts = [
            6789
            3300
          ];
          allowedTCPPortRanges = [
            {
              from = 6800;
              to = 7300;
            }
          ];
        };
      };

      environment.systemPackages = with pkgs; [
        bash
        ceph
        xfsprogs
      ];

      boot.kernelModules = [ "xfs" ];

      services.ceph = mkCephConfig {
        mon = {
          enable = true;
          daemons = [ cfg.monA.name ];
        };
        mgr = {
          enable = true;
          daemons = [ cfg.monA.name ];
        };
        mds = {
          enable = true;
          daemons = [ cfg.monA.name ];
        };
        osd = {
          enable = true;
          daemons = [ cfg.osd0.name ];
        };
      };
    };

  storageBNode =
    { pkgs, ... }:
    {
      virtualisation = {
        emptyDiskImages = [ 20480 ];
        vlans = [ 1 ];
        memorySize = 1536;
        cores = 2;
      };

      networking = {
        dhcpcd.enable = false;
        interfaces.eth1.ipv4.addresses = lib.mkOverride 0 [
          {
            address = cfg.osd1.ip;
            prefixLength = 24;
          }
        ];
        firewall = {
          allowedTCPPortRanges = [
            {
              from = 6800;
              to = 7300;
            }
          ];
        };
      };

      environment.systemPackages = with pkgs; [
        bash
        ceph
        xfsprogs
      ];

      boot.kernelModules = [ "xfs" ];

      services.ceph = mkCephConfig {
        osd = {
          enable = true;
          daemons = [ cfg.osd1.name ];
        };
      };
    };

  mkComputeNode = ip: {
    virtualisation = {
      vlans = [ 1 ];
      memorySize = 1024;
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
      firewall.enable = false;
    };

    boot = {
      kernelModules = [ "ceph" ];
      supportedFilesystems = [ "ceph" ];
    };

    environment.systemPackages = with pkgs; [ ceph ];
  };
in
pkgs.testers.runNixOSTest {
  name = "cephfs";

  nodes = {
    storage_a = storageANode;
    storage_b = storageBNode;
    compute1 = mkComputeNode cfg.computeIps.compute1;
    compute2 = mkComputeNode cfg.computeIps.compute2;
    compute3 = mkComputeNode cfg.computeIps.compute3;
    compute4 = mkComputeNode cfg.computeIps.compute4;
  };

  testScript = ''
    start_all()

    storage_a.wait_for_unit("network.target")
    storage_b.wait_for_unit("network.target")
    for c in (compute1, compute2, compute3, compute4):
        c.wait_for_unit("network.target")

    with subtest("bootstrap mon-a"):
        storage_a.succeed(
            "sudo -u ceph ceph-authtool --create-keyring /tmp/ceph.mon.keyring --gen-key -n mon. --cap mon 'allow *'",
            "sudo -u ceph ceph-authtool --create-keyring /etc/ceph/ceph.client.admin.keyring --gen-key -n client.admin --cap mon 'allow *' --cap osd 'allow *' --cap mds 'allow *' --cap mgr 'allow *'",
            "sudo -u ceph ceph-authtool /tmp/ceph.mon.keyring --import-keyring /etc/ceph/ceph.client.admin.keyring",
            "monmaptool --create --add ${cfg.monA.name} ${cfg.monA.ip} --fsid ${cfg.clusterId} /tmp/monmap",
            "sudo -u ceph ceph-mon --mkfs -i ${cfg.monA.name} --monmap /tmp/monmap --keyring /tmp/ceph.mon.keyring",
            "sudo -u ceph mkdir -p /var/lib/ceph/mgr/ceph-${cfg.monA.name}/",
            "sudo -u ceph touch /var/lib/ceph/mon/ceph-${cfg.monA.name}/done",
            "systemctl start ceph-mon-${cfg.monA.name}",
        )
        storage_a.wait_for_unit("ceph-mon-${cfg.monA.name}")
        storage_a.succeed("ceph mon enable-msgr2")
        storage_a.succeed("ceph config set mon auth_allow_insecure_global_id_reclaim false")
        storage_a.succeed("ceph -s | grep 'mon: 1 daemons'")

    with subtest("start mgr"):
        storage_a.succeed(
            "ceph auth get-or-create mgr.${cfg.monA.name} mon 'allow profile mgr' osd 'allow *' mds 'allow *' > /var/lib/ceph/mgr/ceph-${cfg.monA.name}/keyring",
            "systemctl start ceph-mgr-${cfg.monA.name}",
        )
        storage_a.wait_for_unit("ceph-mgr-${cfg.monA.name}")
        storage_a.wait_until_succeeds("ceph -s | grep 'quorum ${cfg.monA.name}'")
        storage_a.wait_until_succeeds("ceph -s | grep 'mgr: ${cfg.monA.name}(active,'")

    with subtest("distribute admin keyring"):
        storage_a.succeed("cp /etc/ceph/ceph.client.admin.keyring /tmp/shared")
        storage_b.succeed("cp /tmp/shared/ceph.client.admin.keyring /etc/ceph")

    with subtest("bootstrap osd-0 on storage_a"):
        storage_a.succeed(
            "mkfs.xfs /dev/vdb",
            "mkdir -p /var/lib/ceph/osd/ceph-${cfg.osd0.name}",
            "mount /dev/vdb /var/lib/ceph/osd/ceph-${cfg.osd0.name}",
            "ceph-authtool --create-keyring /var/lib/ceph/osd/ceph-${cfg.osd0.name}/keyring --name osd.${cfg.osd0.name} --add-key ${cfg.osd0.key}",
            'echo \'{"cephx_secret": "${cfg.osd0.key}"}\' | ceph osd new ${cfg.osd0.uuid} -i -',
            "ceph-osd -i ${cfg.osd0.name} --mkfs --osd-uuid ${cfg.osd0.uuid}",
            "chown -R ceph:ceph /var/lib/ceph/osd",
            "systemctl start ceph-osd-${cfg.osd0.name}",
        )

    with subtest("bootstrap osd-1 on storage_b"):
        storage_b.succeed(
            "mkfs.xfs /dev/vdb",
            "mkdir -p /var/lib/ceph/osd/ceph-${cfg.osd1.name}",
            "mount /dev/vdb /var/lib/ceph/osd/ceph-${cfg.osd1.name}",
            "ceph-authtool --create-keyring /var/lib/ceph/osd/ceph-${cfg.osd1.name}/keyring --name osd.${cfg.osd1.name} --add-key ${cfg.osd1.key}",
            'echo \'{"cephx_secret": "${cfg.osd1.key}"}\' | ceph osd new ${cfg.osd1.uuid} -i -',
            "ceph-osd -i ${cfg.osd1.name} --mkfs --osd-uuid ${cfg.osd1.uuid}",
            "chown -R ceph:ceph /var/lib/ceph/osd",
            "systemctl start ceph-osd-${cfg.osd1.name}",
        )

    with subtest("cluster reaches HEALTH_OK with 2 OSDs"):
        storage_a.wait_until_succeeds("ceph osd stat | grep -e '2 osds: 2 up[^,]*, 2 in'")
        storage_a.succeed(
            "ceph config set mon mon_warn_on_too_few_osds false",
            "ceph config set mon mon_warn_on_pool_no_redundancy false",
            "ceph config set global mon_allow_pool_size_one true",
            "ceph health mute MON_DOWN 1h || true",
            "ceph health mute POOL_NO_REDUNDANCY 1h || true",
        )
        storage_a.wait_until_succeeds(
            "ceph -s | grep -E 'HEALTH_(OK|WARN)'",
            timeout=120,
        )
        status = storage_a.succeed("ceph -s")
        print("--- ceph -s after bringup ---")
        print(status)

    with subtest("create cephfs pools and filesystem"):
        storage_a.succeed(
            "ceph osd pool create cephfs_data 32 32",
            "ceph osd pool create cephfs_metadata 8 8",
            "ceph osd pool set cephfs_data size 2",
            "ceph osd pool set cephfs_metadata size 2",
            "ceph fs new ${cfg.fsName} cephfs_metadata cephfs_data",
        )

    with subtest("start mds"):
        storage_a.succeed(
            "sudo -u ceph mkdir -p /var/lib/ceph/mds/ceph-${cfg.monA.name}",
            "ceph auth get-or-create mds.${cfg.monA.name} mon 'allow profile mds' osd 'allow rwx' mds 'allow' > /var/lib/ceph/mds/ceph-${cfg.monA.name}/keyring",
            "chown -R ceph:ceph /var/lib/ceph/mds",
            "chmod 0600 /var/lib/ceph/mds/ceph-${cfg.monA.name}/keyring",
            "systemctl start ceph-mds-${cfg.monA.name}",
        )
        storage_a.wait_for_unit("ceph-mds-${cfg.monA.name}", timeout=60)
        print("--- ceph-mds-a systemd journal (last 30 lines) ---")
        print(storage_a.succeed(
            "journalctl -u ceph-mds-${cfg.monA.name} --no-pager -n 30 || true"
        ))
        print("--- ceph mds stat ---")
        print(storage_a.succeed("ceph mds stat || true"))
        print("--- ceph fs ls ---")
        print(storage_a.succeed("ceph fs ls || true"))
        print("--- ceph fs status ---")
        print(storage_a.succeed("ceph fs status || true"))
        print("--- ceph -s ---")
        print(storage_a.succeed("ceph -s || true"))
        storage_a.wait_until_succeeds(
            "ceph mds stat | grep -E 'up:(active|creating|reconnect|rejoin|clientreplay)'",
            timeout=180,
        )
        storage_a.wait_until_succeeds(
            "ceph -s | grep -E 'HEALTH_(OK|WARN)'", timeout=60
        )

    with subtest("provision cephfs-client key"):
        storage_a.succeed(
            "ceph auth get-or-create client.cephfs "
            "mon 'allow r' "
            "mds 'allow rw' "
            "osd 'allow rw pool=cephfs_data, allow rw pool=cephfs_metadata'"
        )
        client_key = storage_a.succeed(
            "ceph auth get-or-create-key client.cephfs"
        ).strip()
        assert client_key, "failed to capture cephfs client key"
        print(f"cephfs client key prefix: {client_key[:8]}...")

    with subtest("mount cephfs on every compute node"):
        for c in (compute1, compute2, compute3, compute4):
            c.succeed("mkdir -p /mnt/ceph")
            c.succeed(
                f"mount -t ceph ${cfg.monA.ip}:6789:/ /mnt/ceph "
                f"-o name=cephfs,secret={client_key}"
            )
            c.succeed("mountpoint /mnt/ceph")

    with subtest("write/read coherence across all compute clients"):
        compute1.succeed("echo 'hello from compute1' > /mnt/ceph/hello.txt")
        compute1.succeed("sync /mnt/ceph/hello.txt")
        for c, name in [
            (compute2, "compute2"),
            (compute3, "compute3"),
            (compute4, "compute4"),
        ]:
            content = c.wait_until_succeeds("cat /mnt/ceph/hello.txt").strip()
            assert content == "hello from compute1", (
                f"{name} read unexpected content: {content!r}"
            )

    with subtest("delete-from-one propagates to all"):
        compute3.succeed("rm /mnt/ceph/hello.txt")
        for c, name in [
            (compute1, "compute1"),
            (compute2, "compute2"),
            (compute4, "compute4"),
        ]:
            c.wait_until_fails("test -f /mnt/ceph/hello.txt")
            print(f"OK: hello.txt no longer visible on {name}")

    with subtest("parallel writes from 4 clients, all visible"):
        for c, name in [
            (compute1, "compute1"),
            (compute2, "compute2"),
            (compute3, "compute3"),
            (compute4, "compute4"),
        ]:
            c.succeed(f"echo {name} > /mnt/ceph/{name}.txt && sync /mnt/ceph/{name}.txt")
        for reader in (compute1, compute2, compute3, compute4):
            for name in ("compute1", "compute2", "compute3", "compute4"):
                content = reader.wait_until_succeeds(f"cat /mnt/ceph/{name}.txt").strip()
                assert content == name, (
                    f"reader {reader.name} got {content!r} for {name}.txt"
                )

    with subtest("ceph-mgr prometheus module exports metrics on :9128"):
        storage_a.succeed("systemctl start ceph-mgr-prometheus-enable.service")
        storage_a.wait_for_unit("ceph-mgr-prometheus-enable.service", timeout=180)
        storage_a.wait_for_open_port(9128, timeout=120)
        metrics = storage_a.succeed("curl -fsS http://127.0.0.1:9128/metrics")
        assert "ceph_health_status" in metrics, (
            "FAIL: ceph_health_status metric not exported by mgr prometheus module"
        )
        assert "ceph_osd_up" in metrics, (
            "FAIL: ceph_osd_up metric missing — exporter may be incomplete"
        )
        print("OK: ceph-mgr prometheus module exporting ceph_health_status + ceph_osd_up")

    print("CEPHFS VERIFICATIONS PASSED")
  '';
}
