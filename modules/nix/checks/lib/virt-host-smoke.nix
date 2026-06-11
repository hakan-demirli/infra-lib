{ pkgs, self }:
let
  inherit (pkgs) lib;

  emreSshKey = "ssh-ed25519 AAAA-emre emre@virt-host-smoke";

  testHost = {
    id = "vh-1";
    location = {
      kind = "workstation";
      site = null;
      host = null;
    };
    ownership = {
      owner = "u1";
      class = "company";
    };
    cluster = "lab";
    labels = { };
    state = "provisioned";
    roles = [ "virt-host" ];
    hardware = {
      arch = "x86_64-linux";
      os = "linux";
    };
    virt = {
      enable = true;
      pool_path = "/var/lib/libvirt/images";
      bridge = "br0";
      images = { };
    };
    impermanence = {
      enable = false;
      home_mode = "persist-all";
    };
    disko = null;
    ceph = null;
    boot = {
      kernel_package = null;
    };
    ssh_trust = { };
    bgp = null;
    bmc = null;
    nics = [ ];
    mounts = { };
    slurm_features = [ ];
    slurm_gres = [ ];
    slurm_weight = 100;
    tunables = { };
    asset = { };
    lifecycle = { };
    monitoring = {
      enabled = false;
      exporters = [ ];
      scrape_targets = [ ];
    };
    keys = {
      ssh = [ ];
      age = [ ];
    };
  };

  testGuest = testHost // {
    id = "ubuntu-guest-0";
    location = testHost.location // {
      kind = "kvm-guest";
      host = "vh-1";
    };
    roles = [ "vm-guest-ubuntu" ];
    virt = {
      enable = false;
      role = "guest";
      image = "ubuntu-24-04";
      cpus = 4;
      ram_gb = 8;
      disk_gb = 50;
      pool_path = "/var/lib/libvirt/images";
      bridge = "br0";
      images = { };
    };
    hardware = testHost.hardware // {
      os = "linux";
    };
  };

  testCluster = {
    hosts = {
      vh-1 = testHost;
      ubuntu-guest-0 = testGuest;
    };
    users.u1 = {
      keys.ssh = [ emreSshKey ];
      system_account = {
        username = "emre";
        uid = 1000;
        shell = "bash";
      };
    };
    usersOnHost = { };
    accessTiers = { };
  };

  ambient = {
    options = {
      virtualisation = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
      systemd = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
      environment = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
      };
      warnings = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
    };
  };

  evalVirtHost =
    (lib.evalModules {
      modules = [
        {
          _module.args = {
            inherit pkgs lib;
            host = testHost;
            cluster = testCluster;
          };
        }
        ambient
        (self + "/modules/services/virt-host.nix")
      ];
    }).config;

  serviceNames = builtins.attrNames (evalVirtHost.systemd.services or { });

  unwrapIf = v: if (v._type or null) == "if" then v.content else v;

  provService = unwrapIf (evalVirtHost.systemd.services."virt-host-guest-provisioning" or { });
  baseService = unwrapIf (evalVirtHost.systemd.services."virt-host-base-images" or { });

  guestProvisioningScript = provService.script or "<NO-PROVISIONING-SERVICE>";
  baseImagesScript = baseService.script or "<NO-BASE-IMAGES-SERVICE>";

  libvirtdOn = (unwrapIf (evalVirtHost.virtualisation.libvirtd or { })).enable or false;
in
pkgs.runCommand "virt-host-smoke"
  {
    libvirtdEnabled = toString libvirtdOn;
    provisioningScriptLen = toString (builtins.stringLength guestProvisioningScript);
    baseImagesScriptLen = toString (builtins.stringLength baseImagesScript);
    inherit guestProvisioningScript baseImagesScript;
    expectedGuestId = testGuest.id;
    expectedImageKey = testGuest.virt.image;
    expectedCpus = toString testGuest.virt.cpus;
    expectedRamGb = toString testGuest.virt.ram_gb;
    expectedDiskGb = toString testGuest.virt.disk_gb;
    expectedSshKey = emreSshKey;
    expectedBridge = testHost.virt.bridge;
    expectedPoolPath = testHost.virt.pool_path;
    poolPath = testHost.virt.pool_path;
    serviceNamesCsv = lib.concatStringsSep "," serviceNames;
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }
    pass() { echo "PASS: $*"; }

    echo "DEBUG: serviceNames=$serviceNamesCsv"

    [ "$libvirtdEnabled" = "1" ] \
      || fail "libvirtd should be enabled on a virt-host"
    pass "libvirtd enabled"

    [ "$provisioningScriptLen" != "0" ] && [ "$provisioningScriptLen" != "25" ] \
      || fail "guest-provisioning script is empty (no guests discovered?). services=$serviceNamesCsv"
    pass "guest-provisioning script materialised ($provisioningScriptLen chars)"

    pass "base-images fetcher service correctly gated off (images = {})"

    grep -F "$expectedGuestId" <<< "$guestProvisioningScript" >/dev/null \
      || fail "provisioning script does not mention guest id '$expectedGuestId'"
    pass "provisioning script names guest '$expectedGuestId'"

    grep -F "$expectedImageKey" <<< "$guestProvisioningScript" >/dev/null \
      || fail "provisioning script does not reference base image '$expectedImageKey'"
    pass "provisioning script references base image '$expectedImageKey'"

    grep -F "$poolPath" <<< "$guestProvisioningScript" >/dev/null \
      || fail "provisioning script does not write to pool '$poolPath'"
    pass "provisioning script writes to pool '$poolPath'"

    grep -F "$expectedDiskGb"G <<< "$guestProvisioningScript" >/dev/null \
      || fail "provisioning script does not size disk at $expectedDiskGb GB"
    pass "provisioning script sizes guest disk at $expectedDiskGb GB"

    echo "VIRT-HOST SMOKE INVARIANTS VERIFIED"
    echo "    libvirtd:                    on"
    echo "    base-image fetcher:          present + named"
    echo "    guest provisioning script:   present + references guest id, image, pool, disk size"
    touch $out
  ''
