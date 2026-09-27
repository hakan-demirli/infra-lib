{
  pkgs,
  self,
}:
let
  common = {
    imports = [ (self + "/modules/system/boot") ];
    _module.args.host = null;
    virtualisation = {
      useBootLoader = true;
      useEFIBoot = true;
    };
    services.openssh.enable = true;
    system.stateVersion = "26.05";
  };
in
pkgs.testers.runNixOSTest {
  name = "boot-assessment";

  nodes = {
    machine =
      { nodes, ... }:
      {
        imports = [ common ];
        system.extraDependencies = [ nodes.unhealthy.system.build.toplevel ];
      };
    unhealthy =
      { lib, ... }:
      {
        imports = [ common ];
        systemd.services.sshd.serviceConfig.ExecStartPre = lib.mkForce "${pkgs.coreutils}/bin/false";
      };
  };

  testScript =
    { nodes, ... }:
    ''
      healthy = "${nodes.machine.system.build.toplevel}"
      unhealthy = "${nodes.unhealthy.system.build.toplevel}"

      def booted(toplevel):
          machine.succeed(f'test "$(readlink -f /run/current-system)" = {toplevel}')

      def entry(generation):
          return machine.succeed(
              f"grep -l 'version Generation {generation} ' /boot/loader/entries/nixos-*.conf"
          ).strip()

      machine.start(allow_reboot=True)
      machine.wait_for_unit("systemd-bless-boot.service")
      booted(healthy)
      assert "+" not in entry(1), entry(1)

      machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {unhealthy}")
      machine.succeed(f"{unhealthy}/bin/switch-to-configuration boot")
      assert entry(2).endswith("+1.conf"), entry(2)

      machine.reboot()
      machine.wait_for_unit("multi-user.target")
      booted(unhealthy)
      machine.fail("systemctl is-active boot-complete.target")
      machine.fail("systemctl is-active systemd-bless-boot.service")
      assert entry(2).endswith("+0-1.conf"), entry(2)

      machine.reboot()
      machine.wait_for_unit("systemd-bless-boot.service")
      booted(healthy)
      machine.wait_for_unit("sshd.service")
    '';
}
