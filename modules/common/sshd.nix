{ lib, ... }:
with lib;
{
  services.openssh = {
    enable = mkDefault true;
    settings = {
      PasswordAuthentication = mkDefault false;
      PermitRootLogin = mkDefault "prohibit-password";
      KbdInteractiveAuthentication = mkDefault false;
      StreamLocalBindUnlink = mkDefault true;
      AuthorizedKeysFile = mkDefault (
        concatStringsSep " " [
          ".ssh/authorized_keys"
          "/etc/ssh/authorized_keys.d/%u"
          "/etc/cluster/extra-authorized-keys/%u"
        ]
      );
    };
    hostKeys = mkDefault [
      {
        type = "ed25519";
        path = "/etc/ssh/ssh_host_ed25519_key";
      }
      {
        type = "rsa";
        bits = 4096;
        path = "/etc/ssh/ssh_host_rsa_key";
      }
    ];
  };

  systemd.tmpfiles.rules = [
    "d /etc/cluster/extra-authorized-keys 0755 root root -"
  ];
}
