{
  inputs,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    attrValues
    concatStringsSep
    filter
    ;

  yubicoPackages = builtins.attrValues {
    inherit (pkgs)
      yubikey-manager
      yubico-piv-tool
      yubioath-flutter
      pam_u2f
      ;
  };

  usersWithU2f = filter (u: u.system_account != null && u.keys.u2f != [ ]) (
    attrValues inputs.self.lib.inventory.users
  );

  mkAuthLine = u: "${u.system_account.username}:${concatStringsSep ":" u.keys.u2f}";

  authfileText = concatStringsSep "\n" (map mkAuthLine usersWithU2f);

  authfile = pkgs.writeText "u2f_keys" authfileText;
in
{
  services.pcscd.enable = true;
  services.udev.packages = yubicoPackages;
  environment.systemPackages = yubicoPackages;

  security.pam.u2f = {
    enable = true;
    settings = {
      origin = "pam://emre-sudo";
      appid = "pam://emre-sudo";
      cue = true;
      control = "sufficient";
      inherit authfile;
    };
  };

  security.pam.services = {
    sudo.u2fAuth = true;
    hyprlock.u2fAuth = false;
    sddm.u2fAuth = false;
    login.u2fAuth = false;
  };
}
