args@{
  config,
  lib,
  pkgs,
  modulesPath,
  rootKeys,
  ...
}:
let
  installer = args.installer or null;
  isInstaller = installer != null;
  failFastCpio = pkgs.cpio.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./cpio-fail-on-header-overflow.patch ];
  });
  makeInitrd =
    args:
    pkgs.callPackage (pkgs.path + "/pkgs/build-support/kernel/make-initrd-ng.nix") (
      args // { cpio = failFastCpio; }
    );
in
{
  imports = [
    (modulesPath + "/installer/netboot/netboot.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  system.build = rec {
    installerSquashfsManifest = pkgs.runCommand "installer-squashfs-manifest" { } ''
      mkdir "$out"
      stat -c %s ${config.system.build.squashfsStore} > "$out/size"
      sha256sum ${config.system.build.squashfsStore} | cut -d ' ' -f 1 > "$out/sha256"
    '';
    netbootRamdisk = pkgs.lib.mkForce (
      (makeInitrd {
        inherit (config.boot.initrd) compressor compressorArgs;
        prepend = [ "${config.system.build.initialRamdisk}/initrd" ];
        contents = [
          {
            source = config.system.build.squashfsStore;
            target = "/nix-store.squashfs";
          }
        ];
      }).overrideAttrs
        (old: {
          buildCommand = ''
            set -o pipefail
            ${old.buildCommand}
          '';
        })
    );
    image = pkgs.runCommand "image" { buildInputs = [ pkgs.nukeReferences ]; } ''
      mkdir $out
      cp ${config.system.build.kernel}/${config.system.boot.loader.kernelFile} $out/kernel
      cp ${config.system.build.netbootRamdisk}/initrd $out/initrd
      nuke-refs $out/kernel
    '';
    kexec_script = pkgs.writeTextFile {
      executable = true;
      name = "kexec-nixos";
      text =
        if isInstaller then
          ''
            #!${pkgs.stdenv.shell}
            set -euo pipefail

            initial_initrd=${config.system.build.initialRamdisk}/initrd
            squashfs=${config.system.build.squashfsStore}
            squashfs_size="$(<${installerSquashfsManifest}/size)"
            squashfs_hash="$(<${installerSquashfsManifest}/sha256)"
            expected_disk=${lib.escapeShellArg installer.expectedDisk}
            expected_disk_real="$(${pkgs.coreutils}/bin/readlink -f "$expected_disk")"

            staging_device=
            while read -r candidate candidate_type candidate_size; do
              [[ "$candidate_type" == partition ]] || continue
              candidate_real="$(${pkgs.coreutils}/bin/readlink -f "$candidate")"
              parent_name="$(${pkgs.util-linux}/bin/lsblk -dnro PKNAME "$candidate_real")"
              [[ -n "$parent_name" ]] || continue
              parent_real="$(${pkgs.coreutils}/bin/readlink -f "/dev/$parent_name")"
              if [[ "$parent_real" == "$expected_disk_real" ]] && (( candidate_size >= squashfs_size )); then
                staging_device="$candidate_real"
                break
              fi
            done < <(
              ${pkgs.util-linux}/bin/swapon \
                --show=NAME,TYPE,SIZE --bytes --noheadings --raw
            )

            if [[ -z "$staging_device" ]]; then
              echo "installer: no active swap partition on $expected_disk can hold $squashfs_size bytes" >&2
              exit 1
            fi

            staging_partuuid="$(${pkgs.util-linux}/bin/lsblk -dnro PARTUUID "$staging_device")"
            if [[ ! "$staging_partuuid" =~ ^[0-9A-Fa-f-]+$ ]]; then
              echo "installer: staging partition has no valid PARTUUID: $staging_device" >&2
              exit 1
            fi

            echo "installer: staging SquashFS on $staging_device"
            ${pkgs.util-linux}/bin/swapoff "$staging_device"
            ${pkgs.coreutils}/bin/dd \
              if="$squashfs" \
              of="$staging_device" \
              bs=16M \
              conv=fsync \
              status=progress

            ${pkgs.kexec-tools}/bin/kexec -l \
              ${config.system.build.kernel}/${config.system.boot.loader.kernelFile} \
              --initrd="$initial_initrd" \
              --append="init=${builtins.unsafeDiscardStringContext config.system.build.toplevel}/init ${toString config.boot.kernelParams} infra.payload-device=/dev/disk/by-partuuid/$staging_partuuid infra.payload-size=$squashfs_size infra.payload-sha256=$squashfs_hash"

            ${pkgs.coreutils}/bin/sync
            echo "installer: executing kernel"
            ${pkgs.kexec-tools}/bin/kexec -e
          ''
        else
          ''
            #!${pkgs.stdenv.shell}
            set -e
            ${pkgs.kexec-tools}/bin/kexec -l ${image}/kernel \
              --initrd=${image}/initrd \
              --append="init=${builtins.unsafeDiscardStringContext config.system.build.toplevel}/init ${toString config.boot.kernelParams}"
            sync
            echo "executing kernel, filesystems will be improperly umounted"
            ${pkgs.kexec-tools}/bin/kexec -e
          '';
    };
    kexec_tarball = pkgs.callPackage (modulesPath + "/../lib/make-system-tarball.nix") {
      storeContents = [
        {
          object = config.system.build.kexec_script;
          symlink = "/kexec_nixos";
        }
      ];
      contents = [ ];
      compressCommand = "cat";
      compressionExtension = "";
    };
    kexec_tarball_self_extract_script = pkgs.writeTextFile {
      executable = true;
      name = "kexec-nixos";
      text = ''
        #!/bin/sh
        set -eu
        ARCHIVE=`awk '/^__ARCHIVE_BELOW__/ { print NR + 1; exit 0; }' $0`
        tail -n+$ARCHIVE $0 | tar x -C /
        /kexec_nixos $@
        exit 1
        __ARCHIVE_BELOW__
      '';
    };
    kexec_bundle =
      if isInstaller then
        kexec_script
      else
        pkgs.runCommand "kexec_bundle" { } ''
          cat \
            ${kexec_tarball_self_extract_script} \
            ${kexec_tarball}/tarball/nixos-system-${kexec_tarball.system}.tar \
            > $out
          chmod +x $out
        '';
  };

  boot = {
    initrd.availableKernelModules = [
      "ata_piix"
      "uhci_hcd"
    ];
    kernelParams = [
      "panic=30"
      "boot.panic_on_fail"
      "console=ttyS0"
      "console=tty1"
    ];
    kernel.sysctl."vm.overcommit_memory" = "1";
  };
  environment.systemPackages = with pkgs; [ cryptsetup ];
  environment.variables.GC_INITIAL_HEAP_SIZE = "1M";

  networking.hostName = "kexec";

  services = {
    getty.autologinUser = "root";
    openssh = {
      enable = true;
      settings = {
        KbdInteractiveAuthentication = false;
        PasswordAuthentication = false;
      };
    };
    udisks2.enable = false;
  };

  documentation.enable = false;
  documentation.nixos.enable = false;
  fonts.fontconfig.enable = false;
  programs.bash.completion.enable = false;
  programs.command-not-found.enable = false;
  security.polkit.enable = pkgs.lib.mkDefault false;
  security.rtkit.enable = pkgs.lib.mkForce false;
  i18n.supportedLocales = [ (config.i18n.defaultLocale + "/UTF-8") ];

  users.users.root.openssh.authorizedKeys.keys = rootKeys;

  assertions = [
    {
      assertion = rootKeys != [ ];
      message =
        "modules/ops/kexec.nix: rootKeys is empty. The kexec bundle would "
        + "boot a NixOS with no way to SSH in. At least one inventory user "
        + "must have `admin_scopes = [ \"fleet\" ]` and a non-empty `keys.ssh`.";
    }
  ];

  system.stateVersion = "26.05";
}
