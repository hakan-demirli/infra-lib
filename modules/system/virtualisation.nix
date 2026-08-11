{ pkgs, ... }:
let
  patchedLibvirt = pkgs.libvirt.overrideAttrs (previousAttrs: {
    patches = (previousAttrs.patches or [ ]) ++ [
      ./libvirt-node-device-udev-shutdown-deadlock.patch
    ];
  });
in
{
  programs.virt-manager.enable = true;
  networking.firewall.trustedInterfaces = [ "virbr0" ];

  virtualisation.libvirtd = {
    enable = true;
    package = patchedLibvirt;
    qemu.vhostUserPackages = with pkgs; [ virtiofsd ];
    qemu.verbatimConfig = ''
      group = "users"
      remember_owner = 0
    '';
  };

  environment.systemPackages = with pkgs; [
    virtiofsd
    virt-viewer
  ];
}
