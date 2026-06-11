{ lib }:
with lib;
with types;
let
  mac = strMatching "^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$";
  ip4 = strMatching "^([0-9]{1,3}\\.){3}[0-9]{1,3}(/[0-9]{1,2})?$";
  ip6 = strMatching "^[0-9a-fA-F:]+(/[0-9]{1,3})?$";
  slug = strMatching "^[a-z0-9][a-z0-9_-]*$";
  hostId = strMatching "^[a-z][a-z0-9-]*[a-z0-9]$";
  date = strMatching "^[0-9]{4}-[0-9]{2}-[0-9]{2}$";

  memberRole = enum [
    "admin"
    "member"
    "viewer"
  ];

  userCohort = enum [
    "admin"
    "staff"
    "student"
    "reviewer"
    "device"
    "service"
  ];

  osFamily = enum [
    "linux"
    "darwin"
    "openwrt"
    "sonic"
    "frr"
    "generic"
  ];

  nixSystem = enum [
    "x86_64-linux"
    "aarch64-linux"
    "riscv64-linux"
    "x86_64-darwin"
    "aarch64-darwin"
  ];

  secretPath = submodule {
    options = {
      source_key = mkOption { type = str; };
      path = mkOption { type = str; };
      owner = mkOption {
        type = str;
        default = "root";
      };
      group = mkOption {
        type = str;
        default = "root";
      };
      mode = mkOption {
        type = str;
        default = "0400";
      };
    };
  };

  systemAccount = submodule {
    options = {
      username = mkOption { type = strMatching "^[a-z_][a-z0-9_-]{0,31}$"; };
      uid = mkOption { type = ints.between 1000 65535; };
      shell = mkOption {
        type = enum [
          "bash"
          "zsh"
          "fish"
          "nushell"
        ];
        default = "bash";
      };
      groups = mkOption {
        type = listOf str;
        default = [ ];
      };
      home = mkOption {
        type = str;
        default = "/home/PLACEHOLDER";
      };
      hashed_password_key = mkOption {
        type = nullOr str;
        default = null;
      };
    };
  };

  mountSpec = submodule {
    options = {
      backend = mkOption {
        type = enum [
          "nvme"
          "nfs"
          "nfs-rdma"
          "weka"
          "lustre"
          "beegfs"
          "ceph"
          "bind"
        ];
      };
      server = mkOption {
        type = nullOr str;
        default = null;
      };
      path = mkOption {
        type = nullOr str;
        default = null;
      };
      mount = mkOption { type = str; };
      options = mkOption {
        type = listOf str;
        default = [ ];
      };
    };
  };

  networkEgress = submodule {
    options = {
      via = mkOption {
        type = nullOr hostId;
        default = null;
      };
      upstream_dns = mkOption {
        type = listOf ip4;
        default = [ ];
      };
      it_registered_macs = mkOption {
        type = listOf mac;
        default = [ ];
      };
    };
  };

  site = _: {
    options = {
      id = mkOption { type = slug; };
      location = mkOption {
        type = str;
        default = "";
      };
      power_budget_kw = mkOption {
        type = ints.positive;
        default = 1;
      };
      cooling = mkOption {
        type = enum [
          "air"
          "liquid"
          "hybrid"
        ];
        default = "air";
      };
    };
  };

  rack = _: {
    options = {
      id = mkOption { type = slug; };
      site = mkOption { type = slug; };
      position = mkOption {
        type = str;
        default = "";
      };
      power_kw = mkOption {
        type = numbers.positive;
        default = 10;
      };
      switch_id = mkOption {
        type = nullOr str;
        default = null;
      };
    };
  };

  network = _: {
    options = {
      id = mkOption { type = slug; };
      purpose = mkOption {
        type = str;
        default = "";
      };
      vlan_id = mkOption {
        type = nullOr (ints.between 0 4094);
        default = null;
      };
      prefix_v4 = mkOption {
        type = nullOr ip4;
        default = null;
      };
      prefix_v6 = mkOption {
        type = nullOr ip6;
        default = null;
      };
      gateway_v4 = mkOption {
        type = nullOr ip4;
        default = null;
      };
      gateway_v6 = mkOption {
        type = nullOr ip6;
        default = null;
      };
      bgp_asn = mkOption {
        type = nullOr ints.positive;
        default = null;
      };
      vrf = mkOption {
        type = nullOr slug;
        default = null;
      };
      qos_class = mkOption {
        type = enum [
          "best-effort"
          "priority"
          "lossless"
        ];
        default = "best-effort";
      };
      egress = mkOption {
        type = networkEgress;
        default = { };
      };
    };
  };

  role = _: {
    options = {
      id = mkOption { type = slug; };
      description = mkOption {
        type = str;
        default = "";
      };
      kind = mkOption {
        type = enum [
          "nixos"
          "darwin"
        ];
        default = "nixos";
      };
      node_role = mkOption {
        type = enum [
          "compute"
          "login"
          "storage"
          "controller"
          "mgmt"
          "personal"
          "external"
        ];
        default = "personal";
      };
      arch = mkOption {
        type = nullOr nixSystem;
        default = null;
      };
      modules = mkOption {
        type = listOf str;
        default = [ ];
      };
      secret_paths = mkOption {
        type = attrsOf secretPath;
        default = { };
      };
      specialisations = mkOption {
        type = listOf str;
        default = [ ];
      };
      tunables = mkOption {
        type = attrsOf anything;
        default = { };
      };
      boot = mkOption {
        type = enum [
          "pxe"
          "iso"
          "image"
        ];
        default = "pxe";
      };
      mounts = mkOption {
        type = attrsOf mountSpec;
        default = { };
      };
    };
  };

  user = _: {
    options = {
      id = mkOption { type = slug; };
      kind = mkOption {
        type = enum [
          "human"
          "service"
          "machine"
        ];
        default = "human";
      };
      cohort = mkOption {
        type = userCohort;
        default = "staff";
      };
      keys = mkOption {
        type = submodule {
          options = {
            ssh = mkOption {
              type = listOf str;
              default = [ ];
            };
            age = mkOption {
              type = listOf str;
              default = [ ];
            };
            u2f = mkOption {
              type = listOf str;
              default = [ ];
            };
            gpg = mkOption {
              type = submodule {
                options = {
                  signing_key_id = mkOption {
                    type = nullOr str;
                    default = null;
                  };
                  signing_public_key = mkOption {
                    type = nullOr str;
                    default = null;
                  };
                  card_key_id = mkOption {
                    type = nullOr str;
                    default = null;
                  };
                  card_public_key = mkOption {
                    type = nullOr str;
                    default = null;
                  };
                };
              };
              default = { };
            };
          };
        };
        default = { };
      };
      system_account = mkOption {
        type = nullOr systemAccount;
        default = null;
      };
      is_root_anywhere = mkOption {
        type = bool;
        default = false;
      };
      allowed_hosts = mkOption {
        type = listOf str;
        default = [ "all" ];
      };
      xrdp_access = mkOption {
        type = bool;
        default = false;
      };
      expires = mkOption {
        type = nullOr date;
        default = null;
      };
      archived = mkOption {
        type = bool;
        default = false;
      };
      archived_at = mkOption {
        type = nullOr date;
        default = null;
      };
      headscale_user = mkOption {
        type = nullOr slug;
        default = null;
      };
      labels = mkOption {
        type = attrsOf str;
        default = { };
      };
      delivery = mkOption {
        type = submodule {
          options = {
            method = mkOption {
              type = enum [
                "unix"
                "vm"
              ];
              default = "unix";
              description = ''
                "unix"  - regular Linux account on shared hosts; the
                          dotfiles-era / current model.
                "vm"    - user's $HOME ships as a libvirt guest VM
                          managed by a virt-host. The VM joins
                          tailscale on its own; cluster-fs gets
                          virtiofs/9p-shared into the guest.
              '';
            };
            vm_image = mkOption {
              type = nullOr str;
              default = null;
              description = ''
                Image identifier for delivery.method = "vm". Keys
                into host.virt.images.<key> on the parent virt-host.
              '';
            };
            vm_cpus = mkOption {
              type = nullOr ints.positive;
              default = null;
            };
            vm_ram_gb = mkOption {
              type = nullOr ints.positive;
              default = null;
            };
            vm_disk_gb = mkOption {
              type = nullOr ints.positive;
              default = null;
            };
            parent_host = mkOption {
              type = nullOr hostId;
              default = null;
              description = ''
                Which virt-host runs this user's VM. null means
                "scheduler picks" (requires shared FS for VM disk +
                live-migration, neither of which is wired today).
              '';
            };
          };
        };
        default = {
          method = "unix";
        };
      };
    };
  };

  teamMember = submodule {
    options = {
      user = mkOption { type = slug; };
      role = mkOption {
        type = memberRole;
        default = "member";
      };
    };
  };

  team = _: {
    options = {
      id = mkOption { type = slug; };
      description = mkOption {
        type = str;
        default = "";
      };
      members = mkOption {
        type = listOf teamMember;
        default = [ ];
      };
      maintainers = mkOption {
        type = listOf slug;
        default = [ ];
      };
      labels = mkOption {
        type = attrsOf str;
        default = { };
      };
    };
  };

  tierSlurmQos = submodule {
    options = {
      max_nodes = mkOption {
        type = nullOr ints.positive;
        default = null;
      };
      max_wall = mkOption {
        type = str;
        default = "INFINITE";
      };
      priority = mkOption {
        type = ints.unsigned;
        default = 100;
      };
    };
  };

  accessTier = _: {
    options = {
      id = mkOption { type = slug; };
      description = mkOption {
        type = str;
        default = "";
      };
      ssh = mkOption {
        type = submodule {
          options = {
            allowed = mkOption {
              type = bool;
              default = true;
            };
          };
        };
        default = { };
      };
      sudo = mkOption {
        type = nullOr str;
        default = null;
      };
      extra_groups = mkOption {
        type = listOf str;
        default = [ ];
      };
      slurm_qos = mkOption {
        type = nullOr tierSlurmQos;
        default = null;
      };
    };
  };

  nic = submodule {
    options = {
      name = mkOption { type = str; };
      mac = mkOption { type = mac; };
      network = mkOption { type = slug; };
      bond = mkOption {
        type = nullOr slug;
        default = null;
      };
      role = mkOption {
        type = enum [
          "data"
          "mgmt"
          "bmc"
          "storage"
          "dpu"
        ];
        default = "data";
      };
      ipv4 = mkOption {
        type = nullOr ip4;
        default = null;
      };
      ipv6 = mkOption {
        type = nullOr ip6;
        default = null;
      };
    };
  };

  bmc = submodule {
    options = {
      mac = mkOption { type = mac; };
      network = mkOption { type = slug; };
      vendor = mkOption {
        type = enum [
          "supermicro"
          "dell"
          "hpe"
          "lenovo"
          "asrock"
          "other"
        ];
        default = "other";
      };
      ipmi_user = mkOption {
        type = str;
        default = "ADMIN";
      };
    };
  };

  hw = submodule {
    options = {
      chassis = mkOption {
        type = str;
        default = "";
      };
      cpu_sockets = mkOption {
        type = ints.positive;
        default = 2;
      };
      cpu_vendor = mkOption {
        type = enum [
          "amd"
          "intel"
          "arm"
          "other"
        ];
        default = "other";
      };
      cpu_model = mkOption {
        type = str;
        default = "";
      };
      simd_arch = mkOption {
        type = nullOr str;
        default = null;
      };
      ram_gib = mkOption {
        type = ints.positive;
        default = 64;
      };
      arch = mkOption {
        type = nixSystem;
        default = "x86_64-linux";
      };
      os = mkOption {
        type = osFamily;
        default = "linux";
      };
      mainboard = mkOption {
        type = nullOr slug;
        default = null;
      };
      vendor = mkOption {
        type = nullOr slug;
        default = null;
      };
      gpu = mkOption {
        type = nullOr (enum [
          "nvidia"
          "amd"
          "intel"
          "amd+nvidia"
          "intel+nvidia"
          "apple-silicon"
        ]);
        default = null;
      };
      fpgas = mkOption {
        type = listOf anything;
        default = [ ];
      };
      scratch_disks = mkOption {
        type = listOf str;
        default = [ ];
      };
    };
  };

  disko = submodule {
    options = {
      root_disk = mkOption { type = str; };
      layout = mkOption {
        type = enum [
          "btrfs-lvm"
          "btrfs-single"
          "ext4-single"
          "zfs-single"
        ];
        default = "btrfs-lvm";
      };
      swap_size = mkOption {
        type = str;
        default = "8G";
      };
      managed = mkOption {
        type = bool;
        default = false;
      };
    };
  };

  bgp = submodule {
    options = {
      asn = mkOption { type = ints.positive; };
      loopback_v4 = mkOption {
        type = nullOr ip4;
        default = null;
      };
      loopback_v6 = mkOption {
        type = nullOr ip6;
        default = null;
      };
    };
  };

  cephOsdDisk = submodule {
    options = {
      name = mkOption {
        type = str;
        description = "Stable OSD identifier used as the disko key (disk.<name> or lvs.<name>).";
      };
      path = mkOption {
        type = str;
        description = ''
          /dev/disk/by-id/... path to the underlying device. For
          block.db / block.wal roles this is the shared NVMe; many
          entries can share one path.
        '';
      };
      role = mkOption {
        type = enum [
          "data"
          "block.db"
          "block.wal"
        ];
        default = "data";
      };
      class = mkOption {
        type = enum [
          "hdd"
          "ssd"
          "nvme"
        ];
        default = "ssd";
      };
      size_gib = mkOption {
        type = nullOr ints.positive;
        default = null;
      };
      vg_name = mkOption {
        type = str;
        default = "";
      };
      reserve_only = mkOption {
        type = bool;
        default = true;
      };
    };
  };

  hostCeph = submodule {
    options = {
      osd_disks = mkOption {
        type = listOf cephOsdDisk;
        default = [ ];
      };
    };
  };

  location = submodule {
    options = {
      kind = mkOption {
        type = enum [
          "rack"
          "laptop"
          "cloud-vm"
          "kvm-guest"
          "workstation"
          "switch-rack"
          "network-equipment"
        ];
      };
      rack = mkOption {
        type = nullOr slug;
        default = null;
      };
      slot = mkOption {
        type = nullOr ints.unsigned;
        default = null;
      };
      provider = mkOption {
        type = nullOr str;
        default = null;
      };
      host = mkOption {
        type = nullOr hostId;
        default = null;
      };
      site = mkOption {
        type = nullOr slug;
        default = null;
      };
    };
  };

  ownership = submodule {
    options = {
      class = mkOption {
        type = enum [
          "personal"
          "company"
          "leased"
          "borrowed"
        ];
      };
      owner = mkOption {
        type = nullOr slug;
        default = null;
      };
      team = mkOption {
        type = nullOr slug;
        default = null;
      };
      operator = mkOption {
        type = nullOr slug;
        default = null;
      };
      custodian = mkOption {
        type = nullOr slug;
        default = null;
      };
      budget_line = mkOption {
        type = nullOr str;
        default = null;
      };
    };
  };

  lifecycle = submodule {
    options = {
      created_at = mkOption {
        type = nullOr date;
        default = null;
      };
      purchased_at = mkOption {
        type = nullOr date;
        default = null;
      };
      provisioned_at = mkOption {
        type = nullOr date;
        default = null;
      };
      last_audited_at = mkOption {
        type = nullOr date;
        default = null;
      };
      warranty_expires = mkOption {
        type = nullOr date;
        default = null;
      };
      expires_at = mkOption {
        type = nullOr date;
        default = null;
      };
      decommissioned_at = mkOption {
        type = nullOr date;
        default = null;
      };
      cost_usd = mkOption {
        type = nullOr ints.unsigned;
        default = null;
      };
      sponsor = mkOption {
        type = nullOr slug;
        default = null;
      };
    };
  };

  asset = submodule {
    options = {
      serial = mkOption {
        type = nullOr str;
        default = null;
      };
      asset_tag = mkOption {
        type = nullOr str;
        default = null;
      };
      instance_id = mkOption {
        type = nullOr str;
        default = null;
      };
      power_w_typical = mkOption {
        type = nullOr ints.positive;
        default = null;
      };
      power_w_max = mkOption {
        type = nullOr ints.positive;
        default = null;
      };
    };
  };

  hostBoot = submodule {
    options = {
      loader = mkOption {
        type = enum [
          "systemd-boot"
          "grub"
          "grub-bios"
          "raspberry-pi"
          "none"
        ];
        default = "systemd-boot";
      };
      kernel_params = mkOption {
        type = listOf str;
        default = [ ];
      };
      kernel_modules = mkOption {
        type = listOf str;
        default = [ ];
      };
      blacklisted_modules = mkOption {
        type = listOf str;
        default = [ ];
      };
      initrd_modules = mkOption {
        type = listOf str;
        default = [ ];
      };
      kernel_package = mkOption {
        type = nullOr str;
        default = null;
        example = "linuxPackages_5_15";
      };
    };
  };

  hostImpermanence = submodule {
    options = {
      enable = mkOption {
        type = bool;
        default = false;
      };
      persisted_paths = mkOption {
        type = listOf str;
        default = [ ];
        description = ''
          Extra SYSTEM-side directories to bind-mount from
          /persist/system/<X> over /<X>. Appended to the fleet
          defaults declared by `system.impermanence.persistentDirs`
          in modules/system/impermanence.nix.

          This is for things like /var/lib/libvirt, /var/log,
          /var/lib/bluetooth -- daemon state that lives outside the
          user's $HOME.
        '';
      };
      persisted_files = mkOption {
        type = listOf str;
        default = [ ];
      };
      rollback_backend = mkOption {
        type = enum [
          "zfs"
          "btrfs"
          "tmpfs"
          "none"
        ];
        default = "tmpfs";
      };
      home_mode = mkOption {
        type = enum [
          "persist-all"
          "selective"
          "ephemeral"
        ];
        default = "persist-all";
        description = ''
          How user $HOME survives the boot-time root wipe. Only meaningful
          when host.disko.layout supports an independent /home subvolume
          (btrfs-lvm today; future btrfs-* layouts as added). Ignored for
          ext4-single (no subvolumes; /home lives in the single partition
          and is fully stateful).

          "persist-all" (DEFAULT)
              /home is its own btrfs subvolume, untouched by rollback-root.
              ALL user state (browser cookies, bash history, project
              repos, ssh keys, undeclared dotfiles) survives boots.
              Matches normal Linux home semantics.

          "selective"
              /home lives inside the /root subvolume and is WIPED on boot.
              Only the directories named by
                system.impermanence.{persistentUserDirs, extraPersistentUserDirs}
              survive, via bind-mounts from /persist/home/<u>/. The
              dotfiles-era model. Footgun: every new HM service that
              writes user state needs a matching extra entry.

          "ephemeral"
              /home wiped + nothing persisted across boots. Kiosk /
              demo / CI-test-bed mode. The user has nothing across
              reboots except what system.impermanence persists via
              persistentDirs (system side, not user side).
        '';
      };
    };
  };

  host = _: {
    options = {
      id = mkOption { type = hostId; };
      hostname = mkOption {
        type = nullOr str;
        default = null;
      };
      roles = mkOption {
        type = listOf slug;
        default = [ ];
      };
      state = mkOption {
        type = enum [
          "planned"
          "provisioning"
          "provisioned"
          "paused"
          "draining"
          "retired"
          "burn-in"
          "rma"
        ];
        default = "planned";
      };
      replaces = mkOption {
        type = nullOr hostId;
        default = null;
      };
      location = mkOption { type = location; };
      ownership = mkOption { type = ownership; };
      lifecycle = mkOption {
        type = lifecycle;
        default = { };
      };
      asset = mkOption {
        type = asset;
        default = { };
      };
      nics = mkOption {
        type = listOf nic;
        default = [ ];
      };
      bmc = mkOption {
        type = nullOr bmc;
        default = null;
      };
      hardware = mkOption {
        type = hw;
        default = { };
      };
      disko = mkOption {
        type = nullOr disko;
        default = null;
      };
      ceph = mkOption {
        type = hostCeph;
        default = { };
      };
      boot = mkOption {
        type = hostBoot;
        default = { };
      };
      impermanence = mkOption {
        type = hostImpermanence;
        default = { };
      };
      tunables = mkOption {
        type = attrsOf anything;
        default = { };
      };
      labels = mkOption {
        type = attrsOf str;
        default = { };
      };
      bgp = mkOption {
        type = nullOr bgp;
        default = null;
      };
      mounts = mkOption {
        type = attrsOf mountSpec;
        default = { };
      };
      cluster = mkOption {
        type = nullOr slug;
        default = null;
      };
      slurm_features = mkOption {
        type = listOf str;
        default = [ ];
      };
      slurm_gres = mkOption {
        type = listOf str;
        default = [ ];
      };
      slurm_weight = mkOption {
        type = ints.positive;
        default = 100;
      };
      monitoring = mkOption {
        type = submodule {
          options = {
            enabled = mkOption {
              type = bool;
              default = true;
            };
            exporters = mkOption {
              type = listOf (enum [
                "node"
                "smartctl"
                "ipmi"
                "lm-sensors"
                "ceph"
                "slurm"
                "zfs"
              ]);
              default = [ "node" ];
            };
            scrape_targets = mkOption {
              type = listOf str;
              default = [ ];
              example = [ "127.0.0.1:8080" ];
            };
          };
        };
        default = { };
      };
      keys = mkOption {
        type = submodule {
          options = {
            ssh = mkOption {
              type = listOf str;
              default = [ ];
            };
            age = mkOption {
              type = listOf str;
              default = [ ];
            };
          };
        };
        default = { };
      };
      ssh_trust = mkOption {
        type = attrsOf (listOf slug);
        default = { };
      };
      ssh_trust_intent = mkOption {
        type = attrsOf (submodule {
          options = {
            allow_paths = mkOption {
              type = listOf (enum [
                "tailnet"
                "lan"
                "jumpbox"
                "external"
              ]);
              default = [ "tailnet" ];
              description = ''
                Paths intent-check accepts when verifying that the
                ssh_trust grant on this target account is actually
                reachable. Default `["tailnet"]` requires that any
                trusted user's headscale-eligible devices have an ACL
                rule reaching this host on port 22. Add `"lan"` /
                `"jumpbox"` / `"external"` to opt out of that check
                for explicitly-acknowledged out-of-band paths.
              '';
            };
          };
        });
        default = { };
        description = ''
          Per-target ssh_trust intent annotations. Keys mirror keys
          of `ssh_trust`. Targets without an entry default to
          `allow_paths = ["tailnet"]`, i.e. intent-check requires a
          headscale ACL match.
        '';
      };
      virt = mkOption {
        type = submodule {
          options = {
            enable = mkOption {
              type = bool;
              default = false;
            };
            pool_path = mkOption {
              type = str;
              default = "/var/lib/libvirt/images";
              description = "Path to libvirt storage pool for guest disks.";
            };
            bridge = mkOption {
              type = str;
              default = "br0";
              description = "Bridge interface guests attach to.";
            };
            images = mkOption {
              type = attrsOf (submodule {
                options = {
                  url = mkOption { type = str; };
                  sha256 = mkOption { type = str; };
                  format = mkOption {
                    type = enum [
                      "qcow2"
                      "raw"
                    ];
                    default = "qcow2";
                  };
                };
              });
              default = { };
              example = lib.literalExpression ''
                {
                  ubuntu-24-04 = {
                    url = "https://cloud-images.ubuntu.com/.../disk.img";
                    sha256 = "...";
                  };
                }
              '';
            };
          };
        };
        default = { };
      };
    };
  };

  clusterNetwork = submodule {
    options = {
      intra_cluster = mkOption {
        type = enum [
          "mesh"
          "none"
          "spine-leaf"
          "fat-tree"
          "hub-spoke"
          "flat-l2"
        ];
        default = "mesh";
      };
      topology = mkOption {
        type = nullOr slug;
        default = null;
      };
      egress = mkOption {
        type = submodule {
          options = {
            clusters = mkOption {
              type = listOf slug;
              default = [ ];
            };
            internet = mkOption {
              type = bool;
              default = true;
            };
          };
        };
        default = { };
      };
      ingress = mkOption {
        type = submodule {
          options = {
            clusters = mkOption {
              type = listOf slug;
              default = [ ];
            };
            public = mkOption {
              type = listOf str;
              default = [ ];
            };
          };
        };
        default = { };
      };
      storage = mkOption {
        type = submodule {
          options = {
            kind = mkOption {
              type = enum [
                "none"
                "beegfs"
                "nfs"
                "lustre"
                "gpfs"
                "ceph"
                "smb"
              ];
              default = "none";
            };
            ports_tcp = mkOption {
              type = listOf ints.positive;
              default = [ ];
            };
            ports_udp = mkOption {
              type = listOf ints.positive;
              default = [ ];
            };
          };
        };
        default = { };
      };
      tailscale_tag = mkOption {
        type = nullOr str;
        default = null;
      };
    };
  };

  slurmPartition = submodule {
    options = {
      nodes = mkOption {
        type = listOf str;
        default = [ "ALL" ];
      };
      default = mkOption {
        type = bool;
        default = false;
      };
      max_time = mkOption {
        type = str;
        default = "INFINITE";
      };
      gres = mkOption {
        type = nullOr str;
        default = null;
      };
    };
  };

  clusterScheduler = submodule {
    options = {
      kind = mkOption {
        type = enum [
          "slurm"
          "none"
        ];
        default = "none";
      };
      controllers = mkOption {
        type = listOf hostId;
        default = [ ];
      };
      dbd = mkOption {
        type = nullOr hostId;
        default = null;
      };
      backing_db = mkOption {
        type = submodule {
          options = {
            type = mkOption {
              type = enum [
                "mariadb"
                "mariadb-galera"
                "postgres"
              ];
              default = "mariadb";
            };
            nodes = mkOption {
              type = listOf hostId;
              default = [ ];
            };
          };
        };
        default = { };
      };
      partitions = mkOption {
        type = attrsOf slurmPartition;
        default = { };
      };
    };
  };

  clusterMembers = submodule {
    options = {
      hosts = mkOption {
        type = listOf hostId;
        default = [ ];
      };
      roles = mkOption {
        type = listOf slug;
        default = [ ];
      };
    };
  };

  clusterOwnership = submodule {
    options = {
      class = mkOption {
        type = enum [
          "personal"
          "company"
          "leased"
          "borrowed"
        ];
        default = "company";
      };
      owner = mkOption {
        type = nullOr slug;
        default = null;
      };
      team = mkOption {
        type = nullOr slug;
        default = null;
      };
      budget_line = mkOption {
        type = nullOr str;
        default = null;
      };
    };
  };

  tierGrant = either str (attrsOf str);

  clusterTeamGrant = submodule {
    options = {
      team = mkOption { type = slug; };
      tier = mkOption {
        type = tierGrant;
        default = "standard";
      };
      can_submit_to = mkOption {
        type = listOf slug;
        default = [ ];
      };
    };
  };

  clusterUserGrant = submodule {
    options = {
      user = mkOption { type = slug; };
      tier = mkOption {
        type = slug;
        default = "standard";
      };
      can_submit_to = mkOption {
        type = listOf slug;
        default = [ ];
      };
    };
  };

  clusterAccess = submodule {
    options = {
      teams = mkOption {
        type = listOf clusterTeamGrant;
        default = [ ];
      };
      users = mkOption {
        type = listOf clusterUserGrant;
        default = [ ];
      };
    };
  };

  cluster = _: {
    options = {
      id = mkOption { type = slug; };
      description = mkOption {
        type = str;
        default = "";
      };
      kind = mkOption {
        type = enum [
          "shared"
          "personal"
          "adhoc"
          "project"
          "temporary"
        ];
        default = "shared";
      };
      state = mkOption {
        type = enum [
          "planned"
          "active"
          "draining"
          "expiring"
          "retired"
        ];
        default = "active";
      };
      project = mkOption {
        type = nullOr slug;
        default = null;
      };
      parent_cluster = mkOption {
        type = nullOr slug;
        default = null;
      };
      ownership = mkOption {
        type = clusterOwnership;
        default = { };
      };
      lifecycle = mkOption {
        type = lifecycle;
        default = { };
      };
      scheduler = mkOption {
        type = clusterScheduler;
        default = { };
      };
      members = mkOption {
        type = clusterMembers;
        default = { };
      };
      access = mkOption {
        type = clusterAccess;
        default = { };
      };
      network = mkOption {
        type = clusterNetwork;
        default = { };
      };
      keys = mkOption {
        type = submodule {
          options = {
            ssh = mkOption {
              type = listOf str;
              default = [ ];
            };
            age = mkOption {
              type = listOf str;
              default = [ ];
            };
          };
        };
        default = { };
      };
      secret_paths = mkOption {
        type = attrsOf secretPath;
        default = { };
      };
      cluster_fs = mkOption {
        type = nullOr (submodule {
          options = {
            backend = mkOption {
              type = enum [
                "cephfs"
                "nfs"
              ];
            };
            mountpoint = mkOption {
              type = str;
              default = "/mnt/shared";
            };
            cephfs = mkOption {
              type = nullOr (submodule {
                options = {
                  fsid = mkOption { type = str; };
                  fs_name = mkOption {
                    type = str;
                    default = "cephfs";
                  };
                  monitors = mkOption {
                    type = listOf str;
                  };
                  client_name = mkOption {
                    type = str;
                    default = "client.admin";
                  };
                  mds_active = mkOption {
                    type = nullOr hostId;
                    default = null;
                  };
                  mds_standby = mkOption {
                    type = nullOr hostId;
                    default = null;
                  };
                };
              });
              default = null;
            };
            nfs = mkOption {
              type = nullOr (submodule {
                options = {
                  server = mkOption { type = str; };
                  export = mkOption { type = str; };
                };
              });
              default = null;
            };
          };
        });
        default = null;
      };
      labels = mkOption {
        type = attrsOf str;
        default = { };
      };
      synthesised = mkOption {
        type = bool;
        default = false;
      };
    };
  };

  switchPort = submodule {
    options = {
      name = mkOption { type = str; };
      mac = mkOption {
        type = nullOr mac;
        default = null;
      };
      speed_gbps = mkOption {
        type = nullOr ints.positive;
        default = null;
      };
      role = mkOption {
        type = enum [
          "uplink"
          "downlink-host"
          "downlink-switch"
          "mlag-peer"
          "mgmt"
          "oob"
          "unused"
        ];
        default = "unused";
      };
      peer = mkOption {
        type = nullOr str;
        default = null;
      };
      peer_port = mkOption {
        type = nullOr str;
        default = null;
      };
      vlan = mkOption {
        type = nullOr (ints.between 0 4094);
        default = null;
      };
      vlans_tagged = mkOption {
        type = listOf (ints.between 0 4094);
        default = [ ];
      };
      ipv4 = mkOption {
        type = nullOr ip4;
        default = null;
      };
      ipv6 = mkOption {
        type = nullOr ip6;
        default = null;
      };
      bond = mkOption {
        type = nullOr slug;
        default = null;
      };
      description = mkOption {
        type = str;
        default = "";
      };
    };
  };

  switch = _: {
    options = {
      id = mkOption { type = hostId; };
      description = mkOption {
        type = str;
        default = "";
      };
      role = mkOption {
        type = enum [
          "spine"
          "leaf"
          "access"
          "tor"
          "oob"
          "mgmt"
          "core"
          "border"
        ];
        default = "leaf";
      };
      state = mkOption {
        type = enum [
          "planned"
          "provisioning"
          "provisioned"
          "draining"
          "retired"
        ];
        default = "planned";
      };
      location = mkOption { type = location; };
      ownership = mkOption { type = ownership; };
      lifecycle = mkOption {
        type = lifecycle;
        default = { };
      };
      asset = mkOption {
        type = asset;
        default = { };
      };
      hardware = mkOption {
        type = submodule {
          options = {
            vendor = mkOption {
              type = str;
              default = "";
            };
            model = mkOption {
              type = str;
              default = "";
            };
            os = mkOption {
              type = osFamily;
              default = "openwrt";
            };
            os_version = mkOption {
              type = str;
              default = "";
            };
            firmware_image = mkOption {
              type = nullOr str;
              default = null;
            };
          };
        };
        default = { };
      };
      mgmt_ipv4 = mkOption {
        type = nullOr ip4;
        default = null;
      };
      mgmt_ipv6 = mkOption {
        type = nullOr ip6;
        default = null;
      };
      mgmt_network = mkOption {
        type = nullOr slug;
        default = null;
      };
      bgp = mkOption {
        type = nullOr bgp;
        default = null;
      };
      ports = mkOption {
        type = attrsOf switchPort;
        default = { };
      };
      labels = mkOption {
        type = attrsOf str;
        default = { };
      };
    };
  };

  topology = _: {
    options = {
      id = mkOption { type = slug; };
      description = mkOption {
        type = str;
        default = "";
      };
      kind = mkOption {
        type = enum [
          "spine-leaf"
          "leaf-leaf-mesh"
          "hub-spoke"
          "fat-tree"
          "rail-optimized"
          "flat-l2"
          "ring"
          "star"
        ];
      };
      spines = mkOption {
        type = listOf hostId;
        default = [ ];
      };
      leaves = mkOption {
        type = listOf hostId;
        default = [ ];
      };
      edge = mkOption {
        type = listOf hostId;
        default = [ ];
      };
      spine_ports = mkOption {
        type = nullOr ints.positive;
        default = null;
      };
      leaf_uplinks = mkOption {
        type = nullOr ints.positive;
        default = null;
      };
      labels = mkOption {
        type = attrsOf str;
        default = { };
      };
    };
  };

  link = _: {
    options = {
      id = mkOption { type = slug; };
      a = mkOption {
        type = submodule {
          options = {
            node = mkOption { type = hostId; };
            port = mkOption { type = str; };
          };
        };
      };
      b = mkOption {
        type = submodule {
          options = {
            node = mkOption { type = hostId; };
            port = mkOption { type = str; };
          };
        };
      };
      speed_gbps = mkOption {
        type = nullOr ints.positive;
        default = null;
      };
      medium = mkOption {
        type = enum [
          "copper"
          "dac"
          "aoc"
          "fiber-mm"
          "fiber-sm"
          "wireless"
          "virtual"
        ];
        default = "copper";
      };
      bond = mkOption {
        type = nullOr slug;
        default = null;
      };
      labels = mkOption {
        type = attrsOf str;
        default = { };
      };
    };
  };

  project = _: {
    options = {
      id = mkOption { type = slug; };
      description = mkOption {
        type = str;
        default = "";
      };
      state = mkOption {
        type = enum [
          "planned"
          "active"
          "expiring"
          "retired"
        ];
        default = "active";
      };
      kind = mkOption {
        type = enum [
          "permanent"
          "temporary"
          "research"
          "infrastructure"
          "personal"
        ];
        default = "permanent";
      };
      lifecycle = mkOption {
        type = lifecycle;
        default = { };
      };
      sponsor = mkOption {
        type = nullOr slug;
        default = null;
      };
      teams = mkOption {
        type = listOf slug;
        default = [ ];
      };
      notify = mkOption {
        type = listOf slug;
        default = [ ];
      };
      labels = mkOption {
        type = attrsOf str;
        default = { };
      };
    };
  };

in
{
  siteModule = site;
  rackModule = rack;
  networkModule = network;
  roleModule = role;
  userModule = user;
  teamModule = team;
  accessTierModule = accessTier;
  hostModule = host;
  clusterModule = cluster;
  switchModule = switch;
  topologyModule = topology;
  linkModule = link;
  projectModule = project;

  siteType = submodule site;
  rackType = submodule rack;
  networkType = submodule network;
  roleType = submodule role;
  userType = submodule user;
  teamType = submodule team;
  accessTierType = submodule accessTier;
  hostType = submodule host;
  clusterType = submodule cluster;
  switchType = submodule switch;
  topologyType = submodule topology;
  linkType = submodule link;
  projectType = submodule project;

  macType = mac;
  ipv4Type = ip4;
  ipv6Type = ip6;
  slugType = slug;
  hostIdType = hostId;
  memberRoleType = memberRole;
  userCohortType = userCohort;
  nixSystemType = nixSystem;
  osFamilyType = osFamily;
}
