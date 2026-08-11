{ pkgs, self }:
pkgs.testers.runNixOSTest {
  name = "libvirtd-shutdown";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ (self + "/modules/system/virtualisation.nix") ];

      programs.virt-manager.enable = lib.mkForce false;
      virtualisation.libvirtd.extraOptions = [ "--timeout=1" ];

      systemd.services = {
        libvirtd.unitConfig.StartLimitIntervalSec = 0;
        libvirtd-config.unitConfig.StartLimitIntervalSec = 0;
      };

      system.stateVersion = "26.05";
    };

  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")

    for attempt in range(25):
        machine.succeed("systemctl start libvirtd.service")
        machine.wait_until_succeeds(
            'test "$(systemctl show --property=ActiveState --value libvirtd.service)" = inactive',
            timeout=40,
        )
        machine.succeed(
            'test "$(systemctl show --property=Result --value libvirtd.service)" = success'
        )
        machine.fail("systemctl is-failed --quiet libvirtd.service")
  '';
}
