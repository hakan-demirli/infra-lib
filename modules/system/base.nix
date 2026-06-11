{ config, lib, ... }:
{
  system.stateVersion = "26.05";

  documentation = {
    enable = lib.mkDefault false;
    nixos.enable = lib.mkDefault false;
  };

  programs = {
    bash.completion.enable = true;
    command-not-found.enable = false;
    fuse.userAllowOther = true;
  };

  services = {
    udisks2.enable = lib.mkDefault false;
    dbus.enable = true;
  };

  i18n.supportedLocales = lib.mkDefault [ (config.i18n.defaultLocale + "/UTF-8") ];

  systemd.user.settings.Manager.DefaultEnvironment = ''
    "PATH=${config.system.path}/bin"
  '';

  systemd.settings.Manager.DefaultLimitNOFILE = 1048576;

  hardware.uinput.enable = true;
  hardware.enableRedistributableFirmware = true;

  boot.kernelParams = [
    "console=tty1"
    "mitigations=off"
    "panic=30"
    "boot.panic_on_fail"
  ];
  boot.kernel.sysctl."vm.overcommit_memory" = "0";

  environment = {
    variables = {
      GC_INITIAL_HEAP_SIZE = "1M";
    };
    localBinInPath = true;
  };

  security = {
    pam = {
      services.swaylock = { };
      loginLimits = [
        {
          domain = "*";
          type = "hard";
          item = "nofile";
          value = "1048576";
        }
      ];
    };

    rtkit.enable = lib.mkDefault false;
  };
}
