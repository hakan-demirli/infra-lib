{
  pkgs,
  self,
  inputs,
}:
let
  inherit (pkgs) lib;
  types = import (self + "/modules/lib/types.nix") { inherit lib; };
  parseBoot =
    boot:
    (lib.evalModules {
      modules = [
        {
          options.host = lib.mkOption { type = types.hostType; };
          config.host.boot = boot;
        }
      ];
    }).config.host.boot;
  evaluate =
    {
      boot ? { },
      system ? "x86_64-linux",
      loader ? "systemd-boot",
      extraModule ? { },
    }:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs.host = {
        id = "boot-policy-test";
        boot = parseBoot boot;
      };
      modules = [
        (self + "/modules/system/boot")
        {
          boot.isContainer = true;
          fileSystems."/boot" = {
            device = "none";
            fsType = "vfat";
          };
          system.stateVersion = "26.05";
        }
        extraModule
      ]
      ++ lib.optional (loader == "grub") (self + "/modules/system/boot/grub.nix");
    };
  normal = evaluate { };
  arm = evaluate { system = "aarch64-linux"; };
  fallback = evaluate { boot.efi_registration = "fallback"; };
  grub = evaluate { loader = "grub"; };
  grubFallback = evaluate {
    loader = "grub";
    boot.efi_registration = "fallback";
  };
  incompatible = evaluate {
    loader = "grub";
    boot.efi_registration = "fallback";
    extraModule.boot.loader.efi.canTouchEfiVariables = true;
  };
  invalid = builtins.tryEval (builtins.deepSeq (parseBoot { efi_registration = "invalid"; }) true);
  failures = system: lib.filter (assertion: !assertion.assertion) system.config.assertions;
  checks = {
    default-policy-is-nvram = (parseBoot { }).efi_registration == "nvram";
    fallback-policy-is-accepted =
      (parseBoot { efi_registration = "fallback"; }).efi_registration == "fallback";
    unknown-policy-is-rejected = !invalid.success;
    normal-pc-uses-systemd-boot = normal.config.boot.loader.systemd-boot.enable;
    normal-pc-manages-efi = normal.config.boot.loader.efi.canTouchEfiVariables;
    arm-uefi-manages-efi = arm.config.boot.loader.efi.canTouchEfiVariables;
    fallback-keeps-systemd-boot = fallback.config.boot.loader.systemd-boot.enable;
    fallback-does-not-write-nvram = !fallback.config.boot.loader.efi.canTouchEfiVariables;
    grub-profile-selects-one-loader =
      grub.config.boot.loader.grub.enable && !grub.config.boot.loader.systemd-boot.enable;
    grub-nvram-is-registered =
      grub.config.boot.loader.efi.canTouchEfiVariables
      && !grub.config.boot.loader.grub.efiInstallAsRemovable;
    grub-fallback-is-removable =
      !grubFallback.config.boot.loader.efi.canTouchEfiVariables
      && grubFallback.config.boot.loader.grub.efiInstallAsRemovable;
    valid-policies-pass-assertions = lib.all (system: failures system == [ ]) [
      normal
      arm
      fallback
      grub
      grubFallback
    ];
    incompatible-grub-options-fail = lib.any (
      assertion: lib.hasInfix "efiInstallAsRemovable" assertion.message
    ) (failures incompatible);
  };
  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
pkgs.runCommand "boot-policy"
  {
    failureCount = toString (lib.length failed);
    failureNames = lib.concatStringsSep "," failed;
  }
  ''
    if [ "$failureCount" != 0 ]; then
      echo "failed boot policies: $failureNames" >&2
      exit 1
    fi
    touch "$out"
  ''
