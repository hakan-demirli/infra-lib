{
  config,
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

  cfg = config.services.yubikey;

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
  options.services.yubikey = {
    pamOrigin = lib.mkOption {
      type = lib.types.str;
      default = "pam://yubikey-sudo";
      description = "pam_u2f origin/appid; must match registration.";
    };
  };

  config = {
    services.pcscd.enable = true;
    services.udev.packages = yubicoPackages;
    environment.systemPackages = yubicoPackages;

    security.pam.u2f = {
      enable = true;
      settings = {
        origin = cfg.pamOrigin;
        appid = cfg.pamOrigin;
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
  };
}
