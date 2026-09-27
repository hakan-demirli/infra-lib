{
  config,
  lib,
  host ? null,
  ...
}:
let
  registration = if host == null then "nvram" else (host.boot.efi_registration or "nvram");
  grubEfi = config.boot.loader.grub.enable && config.boot.loader.grub.efiSupport;
  hibernates = host != null && (host.labels.hibernation or null) == "true";
  bootHealthUnits =
    lib.optional config.services.openssh.enable "sshd.service"
    ++ lib.optional config.services.tailscale.enable "tailscaled.service";
in
{
  assertions = [
    {
      assertion = !(hibernates && config.boot.loader.systemd-boot.bootCounting.enable);
      message = "boot counting marks the default entry bad on every resume from hibernation, because systemd-bless-boot does not run after a resume.";
    }
  ];

  boot.loader = {
    systemd-boot = {
      enable = lib.mkDefault true;
      bootCounting = {
        enable = lib.mkDefault (!hibernates);
        tries = lib.mkDefault 1;
      };
    };
    efi.canTouchEfiVariables = lib.mkDefault (registration == "nvram");
    grub.efiInstallAsRemovable = lib.mkIf grubEfi (lib.mkDefault (registration == "fallback"));
  };

  systemd.targets.boot-complete =
    lib.mkIf
      (config.boot.loader.systemd-boot.enable && config.boot.loader.systemd-boot.bootCounting.enable)
      {
        requires = bootHealthUnits;
        after = bootHealthUnits;
      };
}
