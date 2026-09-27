{ config, lib, ... }:
{
  assertions = [
    {
      assertion = lib.all (
        user: !user.isNormalUser || user.autoSubUidGidRange || user.subUidRanges != [ ]
      ) (lib.attrValues config.users.users);
      message = "rootless Podman requires a subordinate UID/GID range for every normal user.";
    }
  ];

  virtualisation = {
    containers.enable = true;
    podman = {
      enable = true;
      dockerCompat = true;
      defaultNetwork.settings.dns_enabled = true;
    };
  };
}
