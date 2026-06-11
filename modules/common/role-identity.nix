{ lib, config, ... }:
with lib;
{
  options.cluster = {
    host = mkOption {
      type = types.attrsOf types.anything;
      description = "Structural copy of the inventory host record.";
      default = { };
    };
    role.name = mkOption {
      type = types.str;
      default = "(unknown)";
    };
    role.tunables = mkOption {
      type = types.attrsOf types.anything;
      default = { };
    };
  };

  config = {
    networking.hostName = mkDefault (config.cluster.host.id or "unknown");
    system.stateVersion = mkDefault "26.05";

    systemd.tmpfiles.rules = [ "d /etc/cluster 0755 root root -" ];

    fileSystems = {
      "/" = mkDefault {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [
          "size=4G"
          "mode=755"
        ];
      };
      "/persist" = mkDefault {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [
          "size=4G"
          "mode=755"
        ];
        neededForBoot = true;
      };
      "/persist/system" = mkDefault {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [
          "size=4G"
          "mode=755"
        ];
        neededForBoot = true;
      };
      "/nix" = mkDefault {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [
          "size=8G"
          "mode=755"
        ];
      };
      "/boot" = mkDefault {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [
          "size=512M"
          "mode=755"
        ];
      };
    };
    boot.loader.systemd-boot.enable = mkDefault true;
    boot.loader.efi.canTouchEfiVariables = mkDefault false;
    users.allowNoPasswordLogin = mkDefault true;

    nixpkgs.config.allowUnfree = mkDefault true;

    cluster.role.name = mkDefault (
      if config.cluster.host ? roles && config.cluster.host.roles != [ ] then
        head config.cluster.host.roles
      else
        "(unknown)"
    );
    cluster.role.tunables = mkDefault (config.cluster.host.tunables or { });
  };
}
