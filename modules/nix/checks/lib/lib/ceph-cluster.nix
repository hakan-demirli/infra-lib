{ lib, ... }:
let
  cfg = rec {
    clusterId = "ce11deaf-0d33-4fed-aafe-c000beefcafe";
    fsName = "cephfs-test";
    monA = {
      name = "a";
      ip = "192.168.1.1";
    };
    monB = {
      name = "b";
      ip = "192.168.1.2";
    };
    monC = {
      name = "c";
      ip = "192.168.1.3";
    };
    osd0 = {
      name = "0";
      key = "AQBCEJNa3s8nHRAANvdsr93KqzBznuIWm2gOGg==";
      uuid = "55ba2294-3e24-478f-bee0-9dca4c231dd9";
    };
    osd1 = {
      name = "1";
      key = "AQBEEJNac00kExAAXEgy943BGyOpVH1LLlHafQ==";
      uuid = "5e97a838-85b6-43b0-8950-cb56d554d1e5";
    };
    osd2 = {
      name = "2";
      key = "AQBFEJNa3s8nHRAANvdsr93KqzBznuIWm2gOGh==";
      uuid = "6a97a838-85b6-43b0-8950-cb56d554d1e6";
    };
    monHostCsv = lib.concatStringsSep "," [
      monA.ip
      monB.ip
      monC.ip
    ];
    monMembersCsv = lib.concatStringsSep "," [
      monA.name
      monB.name
      monC.name
    ];
  };

  mkCephConfig =
    daemonConfig:
    {
      enable = true;
      global = {
        fsid = cfg.clusterId;
        monHost = cfg.monHostCsv;
        monInitialMembers = cfg.monMembersCsv;
      };
    }
    // daemonConfig;

  cephPersistence = osdName: {
    virtualisation.fileSystems."/var/lib/ceph/osd/ceph-${osdName}" = {
      device = "/dev/vdb";
      fsType = "xfs";
      options = [ "nofail" ];
    };
    systemd.tmpfiles.rules = [
      "d /var/lib/ceph-test-state 0755 root root -"
      "C /etc/ceph/ceph.client.admin.keyring 0640 root ceph - /var/lib/ceph-test-state/admin.keyring"
    ];
  };

  mkStorageNode =
    {
      ip,
      monName,
      osdName,
      extraDaemons ? { },
    }:
    { pkgs, ... }:
    lib.mkMerge [
      (cephPersistence osdName)
      {
        virtualisation = {
          emptyDiskImages = [ 20480 ];
          vlans = [ 1 ];
          memorySize = 2048;
          cores = 2;
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
        services.ceph = mkCephConfig (
          {
            mon = {
              enable = true;
              daemons = [ monName ];
            };
          }
          // extraDaemons
        );
      }
    ];

  storageANode = mkStorageNode {
    ip = cfg.monA.ip;
    monName = cfg.monA.name;
    osdName = cfg.osd0.name;
    extraDaemons = {
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
  storageBNode = mkStorageNode {
    ip = cfg.monB.ip;
    monName = cfg.monB.name;
    osdName = cfg.osd1.name;
    extraDaemons = {
      mgr = {
        enable = true;
        daemons = [ cfg.monB.name ];
      };
      mds = {
        enable = true;
        daemons = [ cfg.monB.name ];
      };
      osd = {
        enable = true;
        daemons = [ cfg.osd1.name ];
      };
    };
  };
  storageCNode = mkStorageNode {
    ip = cfg.monC.ip;
    monName = cfg.monC.name;
    osdName = cfg.osd2.name;
    extraDaemons = {
      osd = {
        enable = true;
        daemons = [ cfg.osd2.name ];
      };
    };
  };

  mkClientNode =
    ip:
    { pkgs, ... }:
    {
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

  bootstrapScript = ''
    start_all()

    for s in (storage_a, storage_b, storage_c):
        s.wait_for_unit("network.target")

    with subtest("[cluster fixture] create keyrings + monmap on storage_a"):
        storage_a.succeed(
            "sudo -u ceph ceph-authtool --create-keyring /tmp/ceph.mon.keyring "
            "--gen-key -n mon. --cap mon 'allow *'",
            "sudo -u ceph ceph-authtool --create-keyring /etc/ceph/ceph.client.admin.keyring "
            "--gen-key -n client.admin --cap mon 'allow *' --cap osd 'allow *' "
            "--cap mds 'allow *' --cap mgr 'allow *'",
            "sudo -u ceph ceph-authtool /tmp/ceph.mon.keyring "
            "--import-keyring /etc/ceph/ceph.client.admin.keyring",
            "monmaptool --create "
            "--add ${cfg.monA.name} ${cfg.monA.ip} "
            "--add ${cfg.monB.name} ${cfg.monB.ip} "
            "--add ${cfg.monC.name} ${cfg.monC.ip} "
            "--fsid ${cfg.clusterId} /tmp/monmap",
        )

    with subtest("[cluster fixture] mkfs all 3 mons + distribute keyrings"):
        storage_a.succeed(
            "sudo -u ceph ceph-mon --mkfs -i ${cfg.monA.name} "
            "--monmap /tmp/monmap --keyring /tmp/ceph.mon.keyring",
            "sudo -u ceph mkdir -p /var/lib/ceph/mgr/ceph-${cfg.monA.name}/",
            "sudo -u ceph touch /var/lib/ceph/mon/ceph-${cfg.monA.name}/done",
            "cp /etc/ceph/ceph.client.admin.keyring /var/lib/ceph-test-state/admin.keyring",
            "chmod 0640 /var/lib/ceph-test-state/admin.keyring",
            "chown root:ceph /var/lib/ceph-test-state/admin.keyring",
            "cp /etc/ceph/ceph.client.admin.keyring /tmp/shared/",
            "cp /tmp/ceph.mon.keyring /tmp/shared/",
            "cp /tmp/monmap /tmp/shared/",
        )
        for node, name in (
            (storage_b, "${cfg.monB.name}"),
            (storage_c, "${cfg.monC.name}"),
        ):
            node.succeed(
                "cp /tmp/shared/ceph.client.admin.keyring /etc/ceph/",
                "cp /tmp/shared/ceph.mon.keyring /tmp/ceph.mon.keyring",
                "cp /tmp/shared/monmap /tmp/monmap",
                "chown ceph:ceph /tmp/ceph.mon.keyring /tmp/monmap",
                "chmod 0644 /tmp/monmap",
                "chmod 0600 /tmp/ceph.mon.keyring",
                "chmod 0640 /etc/ceph/ceph.client.admin.keyring",
                "chown root:ceph /etc/ceph/ceph.client.admin.keyring",
                "cp /etc/ceph/ceph.client.admin.keyring /var/lib/ceph-test-state/admin.keyring",
                "chmod 0640 /var/lib/ceph-test-state/admin.keyring",
                "chown root:ceph /var/lib/ceph-test-state/admin.keyring",
                f"sudo -u ceph ceph-mon --mkfs -i {name} "
                f"--monmap /tmp/monmap --keyring /tmp/ceph.mon.keyring",
                f"sudo -u ceph touch /var/lib/ceph/mon/ceph-{name}/done",
            )

    with subtest("[cluster fixture] start all 3 mons + wait for quorum"):
        storage_a.succeed("systemctl start ceph-mon-${cfg.monA.name}")
        storage_b.succeed("systemctl start ceph-mon-${cfg.monB.name}")
        storage_c.succeed("systemctl start ceph-mon-${cfg.monC.name}")
        storage_a.wait_for_unit("ceph-mon-${cfg.monA.name}")
        storage_b.wait_for_unit("ceph-mon-${cfg.monB.name}")
        storage_c.wait_for_unit("ceph-mon-${cfg.monC.name}")
        storage_a.wait_until_succeeds(
            "ceph -s | grep -E '3 daemons.*quorum'", timeout=120
        )

    with subtest("[cluster fixture] post-quorum config"):
        storage_a.succeed("ceph mon enable-msgr2")
        storage_a.succeed(
            "ceph config set mon auth_allow_insecure_global_id_reclaim false"
        )
        storage_a.succeed(
            "ceph config set osd osd_heartbeat_grace 5",
            "ceph config set osd osd_heartbeat_interval 1",
            "ceph config set mon mon_osd_min_down_reporters 1",
            "ceph config set mds mds_beacon_grace 5",
        )

    with subtest("[cluster fixture] active+standby mgr"):
        for node, name in (
            (storage_a, "${cfg.monA.name}"),
            (storage_b, "${cfg.monB.name}"),
        ):
            node.succeed(
                "sudo -u ceph mkdir -p /var/lib/ceph/mgr/ceph-" + name,
                f"ceph auth get-or-create mgr.{name} "
                f"mon 'allow profile mgr' osd 'allow *' mds 'allow *' "
                f"> /var/lib/ceph/mgr/ceph-{name}/keyring",
                f"chown -R ceph:ceph /var/lib/ceph/mgr/ceph-{name}",
                f"systemctl start ceph-mgr-{name}",
            )
            node.wait_for_unit(f"ceph-mgr-{name}")

    with subtest("[cluster fixture] bring up 3 OSDs"):
        osds = [
            (storage_a, "${cfg.osd0.name}", "${cfg.osd0.uuid}", "${cfg.osd0.key}"),
            (storage_b, "${cfg.osd1.name}", "${cfg.osd1.uuid}", "${cfg.osd1.key}"),
            (storage_c, "${cfg.osd2.name}", "${cfg.osd2.uuid}", "${cfg.osd2.key}"),
        ]
        for node, name, uuid, key in osds:
            node.succeed(
                f"umount /var/lib/ceph/osd/ceph-{name} 2>/dev/null || true",
                "mkfs.xfs -f /dev/vdb",
                f"mkdir -p /var/lib/ceph/osd/ceph-{name}",
                f"mount /dev/vdb /var/lib/ceph/osd/ceph-{name}",
                f"ceph-authtool --create-keyring /var/lib/ceph/osd/ceph-{name}/keyring "
                f"--name osd.{name} --add-key {key}",
                f"echo '{{\"cephx_secret\": \"{key}\"}}' | ceph osd new {uuid} -i -",
                f"ceph-osd -i {name} --mkfs --osd-uuid {uuid}",
                f"ceph-authtool --create-keyring /var/lib/ceph/osd/ceph-{name}/keyring "
                f"--name osd.{name} --add-key {key}",
                "chown -R ceph:ceph /var/lib/ceph/osd",
                f"chmod 0600 /var/lib/ceph/osd/ceph-{name}/keyring",
                f"systemctl start ceph-osd-{name}",
            )
        storage_a.wait_until_succeeds(
            "ceph osd stat | grep -e '3 osds: 3 up[^,]*, 3 in'", timeout=120
        )

    with subtest("[cluster fixture] create cephfs (replica=3, min_size=2)"):
        storage_a.succeed(
            "ceph osd pool create cephfs_data 32 32",
            "ceph osd pool create cephfs_metadata 8 8",
            "ceph osd pool set cephfs_data size 3",
            "ceph osd pool set cephfs_data min_size 2",
            "ceph osd pool set cephfs_metadata size 3",
            "ceph osd pool set cephfs_metadata min_size 2",
            "ceph fs new ${cfg.fsName} cephfs_metadata cephfs_data",
        )

    with subtest("[cluster fixture] active+standby mds"):
        for node, name in (
            (storage_a, "${cfg.monA.name}"),
            (storage_b, "${cfg.monB.name}"),
        ):
            node.succeed(
                "sudo -u ceph mkdir -p /var/lib/ceph/mds/ceph-" + name,
                f"ceph auth get-or-create mds.{name} "
                f"mon 'allow profile mds' osd 'allow rwx' mds 'allow' "
                f"> /var/lib/ceph/mds/ceph-{name}/keyring",
                f"chown -R ceph:ceph /var/lib/ceph/mds/ceph-{name}",
                f"chmod 0600 /var/lib/ceph/mds/ceph-{name}/keyring",
                f"systemctl start ceph-mds-{name}",
            )
            node.wait_for_unit(f"ceph-mds-{name}", timeout=60)
        storage_a.wait_until_succeeds(
            "ceph mds stat | grep -E 'up:(active|creating|reconnect|rejoin|clientreplay)'",
            timeout=180,
        )

    with subtest("[cluster fixture] HEALTH ready (OK or WARN)"):
        storage_a.wait_until_succeeds(
            "ceph -s | grep -E 'HEALTH_(OK|WARN)'", timeout=180
        )

    with subtest("[cluster fixture] provision cephfs client key"):
        storage_a.succeed(
            "ceph auth get-or-create client.cephfs "
            "mon 'allow r' mds 'allow rw' "
            "osd 'allow rw pool=cephfs_data, allow rw pool=cephfs_metadata'"
        )
        client_key = storage_a.succeed(
            "ceph auth get-or-create-key client.cephfs"
        ).strip()
  '';

  mkClientMount = clientVar: ''
    with subtest("[cluster fixture] mount cephfs on ${clientVar}"):
        ${clientVar}.succeed("mkdir -p /mnt/ceph")
        ${clientVar}.succeed(
            f"mount -t ceph ${cfg.monA.ip}:6789,${cfg.monB.ip}:6789,${cfg.monC.ip}:6789:/ "
            f"/mnt/ceph -o name=cephfs,secret={client_key}"
        )
        ${clientVar}.succeed("mountpoint /mnt/ceph")
  '';

in
{
  inherit
    cfg
    storageANode
    storageBNode
    storageCNode
    mkClientNode
    bootstrapScript
    mkClientMount
    ;
}
