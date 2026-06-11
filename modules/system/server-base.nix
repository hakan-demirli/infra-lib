{
  config,
  lib,
  pkgs,
  host ? null,
  ...
}:
let
  cfg = config.system.server;

  hostKernelPackage =
    if host == null then
      null
    else
      let
        attr = host.boot.kernel_package or null;
      in
      if attr == null then null else pkgs.${attr};
in
{
  options.system.server = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Activate server-base config (fonts.minimal, multi-user target, server-cli packages).";
    };
    hostName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional server hostname override (rarely needed; networking.hostName is the default).";
    };
  };

  config = lib.mkIf cfg.enable {
    networking = {
      hostName = lib.mkIf (cfg.hostName != null) (lib.mkForce cfg.hostName);
      networkmanager.enable = lib.mkDefault true;
    };

    systemd.defaultUnit = "multi-user.target";

    environment.systemPackages = with pkgs; [
      git
      htop
      tmux
      jq
    ];

    boot.kernelPackages =
      if hostKernelPackage != null then hostKernelPackage else lib.mkDefault pkgs.linuxPackages_latest;
  };
}
