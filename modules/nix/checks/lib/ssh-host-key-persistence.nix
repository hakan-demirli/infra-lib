{
  pkgs,
  self,
  inputs,
}:
let
  fixture = (import ./fixtures/test-ed25519-keys.nix { inherit pkgs; }).admin;
  common = {
    imports = [
      inputs.impermanence.nixosModules.impermanence
      (self + "/modules/system/impermanence.nix")
    ];
    _module.args = {
      host = {
        id = "ssh-persistence-test";
        disko = {
          managed = true;
          layout = "btrfs-lvm";
        };
        impermanence = {
          enable = true;
          rollback_backend = "btrfs";
          home_mode = "ephemeral";
          persisted_paths = [ ];
          persisted_files = [ ];
        };
      };
      cluster = { };
    };
    virtualisation = {
      diskImage = null;
      emptyDiskImages = [
        {
          size = 128;
          driveConfig.deviceExtraOpts.serial = "persist";
        }
      ];
      fileSystems."/persist" = {
        device = "/dev/disk/by-id/virtio-persist";
        fsType = "ext4";
        autoFormat = true;
        neededForBoot = true;
      };
    };
    boot.initrd.systemd.enable = true;
    services.openssh.enable = true;
    system.stateVersion = "26.05";
  };
in
pkgs.testers.runNixOSTest {
  name = "ssh-host-key-persistence";
  nodes = {
    fresh = common;
    existing =
      { lib, ... }:
      {
        imports = [ common ];
        services.openssh.hostKeys = [
          {
            type = "ed25519";
            path = "/etc/ssh/custom_host_key";
          }
        ];
        system.activationScripts = {
          seedHostKey = {
            deps = [ "etc" ];
            text = ''
              if [[ ! -s /persist/system/etc/ssh/custom_host_key ]]; then
                install -d -m 0755 /etc/ssh
                install -m 0600 ${fixture.privateKey} /etc/ssh/custom_host_key
                ${pkgs.openssh}/bin/ssh-keygen -y -f /etc/ssh/custom_host_key > /etc/ssh/custom_host_key.pub
              fi
            '';
          };
          preparePersistentHostIdentity.deps = lib.mkAfter [ "seedHostKey" ];
        };
      };
  };
  testScript = ''
    start_all()
    cases = [
        (fresh, ["/etc/ssh/ssh_host_ed25519_key", "/etc/ssh/ssh_host_rsa_key"]),
        (existing, ["/etc/ssh/custom_host_key"]),
    ]
    for machine, keys in cases:
        machine.wait_for_unit("sshd.service")
        machine.succeed("test $(findmnt -n -o FSTYPE /) = tmpfs")
        public_keys = {key: machine.succeed(f"ssh-keygen -y -f {key}") for key in keys}
        for key in keys:
            machine.succeed(f"test -s /persist/system{key}")
            machine.succeed(f"test -s /persist/system{key}.pub")
            machine.succeed(f"test $(stat -c %a /persist/system{key}) = 600")
            machine.succeed(f"test $(stat -c %a /persist/system{key}.pub) = 644")
        for attempt in range(2):
            machine.succeed("touch /root/volatile-probe")
            machine.shutdown()
            machine.start()
            machine.wait_for_unit("sshd.service")
            machine.fail("test -e /root/volatile-probe")
            for key in keys:
                assert machine.succeed(f"ssh-keygen -y -f {key}") == public_keys[key]
                machine.succeed(f"test $(stat -c %a /persist/system{key}) = 600")
                machine.succeed(f"test $(stat -c %a /persist/system{key}.pub) = 644")
    existing.succeed("cmp /persist/system/etc/ssh/custom_host_key ${fixture.privateKey}")
  '';
}
