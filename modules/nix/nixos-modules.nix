_: {
  flake.nixosModules = {
    role-identity = ../common/role-identity.nix;
    role-identity-darwin = ../common/role-identity-darwin.nix;
    cluster-users = ../common/cluster-users.nix;
    role-secrets = ../common/role-secrets.nix;
    host-disko = ../common/host-disko.nix;
    node-exporter = ../common/node-exporter.nix;
    smartctl-exporter = ../common/smartctl-exporter.nix;
    ipmi-exporter = ../common/ipmi-exporter.nix;
    vector-shipper = ../common/vector-shipper.nix;
    sshd = ../common/sshd.nix;
    auto-upgrade = ../common/auto-upgrade.nix;
    overlays = ../common/overlays.nix;

    system-base = ../system/base.nix;
    system-server-base = ../system/server-base.nix;
    system-laptop-base = ../system/laptop-base.nix;
    system-impermanence = ../system/impermanence.nix;
    system-ephemeral-root = ../system/ephemeral-root.nix;
    system-amd-graphics = ../system/amd-graphics.nix;
    system-intel = ../system/intel.nix;
    system-nvidia = ../system/nvidia.nix;
    system-fonts = ../system/fonts.nix;
    system-bluetooth = ../system/bluetooth.nix;
    system-hibernation = ../system/hibernation.nix;
    system-polkit = ../system/polkit.nix;
    system-sound = ../system/sound.nix;
    system-battery = ../system/battery.nix;
    system-virtualisation = ../system/virtualisation.nix;
    system-automount = ../system/automount.nix;
    system-gnupg = ../system/gnupg.nix;
    system-locale = ../system/locale.nix;
    system-v4l2loopback = ../system/v4l2loopback.nix;

    ops-kexec = ../ops/kexec.nix;
  };
}
