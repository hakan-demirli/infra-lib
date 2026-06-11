{
  installer,
  lib,
  pkgs,
  ...
}:
let
  marker = "infra.install=${installer.hostId}";
  squashfsMountUnit = "sysroot-nix-.ro\\x2dstore.mount";
in
{
  boot.kernelParams = [ marker ];
  netboot.squashfsCompression = "zstd -Xcompression-level 6";

  boot.initrd.systemd.services.assemble-installer-squashfs = {
    description = "Load and verify staged installer SquashFS";
    unitConfig.DefaultDependencies = false;
    requiredBy = [ squashfsMountUnit ];
    before = [ squashfsMountUnit ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    path = [
      pkgs.coreutils
      pkgs.util-linux
    ];
    script = ''
      set -euo pipefail

      payload_device=
      expected_size=
      expected_hash=
      for argument in $(</proc/cmdline); do
        case "$argument" in
          infra.payload-device=*) payload_device="''${argument#*=}" ;;
          infra.payload-size=*) expected_size="''${argument#*=}" ;;
          infra.payload-sha256=*) expected_hash="''${argument#*=}" ;;
        esac
      done

      [[ "$payload_device" == /dev/disk/by-partuuid/* ]]
      [[ "$expected_size" =~ ^[1-9][0-9]*$ ]]
      [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]]

      for _ in $(seq 1 100); do
        [[ -b "$payload_device" ]] && break
        sleep 0.1
      done
      if [[ ! -b "$payload_device" ]]; then
        echo "installer: staged payload device did not appear: $payload_device" >&2
        exit 1
      fi

      device_size="$(blockdev --getsize64 "$payload_device")"
      if (( device_size < expected_size )); then
        echo "installer: staged device has $device_size bytes; $expected_size required" >&2
        exit 1
      fi

      output=/nix-store.squashfs
      rm -f "$output"
      actual_hash="$(
        dd \
          if="$payload_device" \
          bs=16M \
          iflag=count_bytes \
          count="$expected_size" \
          status=progress \
          | tee "$output" \
          | sha256sum \
          | cut -d ' ' -f 1
      )"
      actual_size="$(stat -c %s "$output")"

      if [[ "$actual_size" != "$expected_size" ]]; then
        echo "installer: SquashFS size mismatch: expected $expected_size, got $actual_size" >&2
        exit 1
      fi
      if [[ "$actual_hash" != "$expected_hash" ]]; then
        echo "installer: SquashFS hash mismatch: expected $expected_hash, got $actual_hash" >&2
        exit 1
      fi

      echo "installer: verified SquashFS ($actual_size bytes)"
    '';
  };

  assertions = [
    {
      assertion = installer.hostId != "";
      message = "Disko installer hostId must not be empty.";
    }
    {
      assertion = lib.hasPrefix "/dev/disk/by-id/" installer.expectedDisk;
      message = "Disko installer expectedDisk must be a stable /dev/disk/by-id path.";
    }
  ];

  systemd.services.disko-installer = {
    description = "Install embedded NixOS system for ${installer.hostId}";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    unitConfig.ConditionKernelCommandLine = marker;
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    path = with pkgs; [
      coreutils
      util-linux
    ];
    script = ''
      set -euo pipefail

      expected_disk=${lib.escapeShellArg installer.expectedDisk}

      echo "installer: verifying $expected_disk for ${installer.hostId}"
      test -b "$expected_disk"
      test "$(lsblk -dn -o TYPE "$expected_disk")" = disk

      swapoff -a || true

      echo "installer: applying embedded Disko configuration"
      ${installer.diskoScript}

      mountpoint -q /mnt
      mountpoint -q /mnt/nix
      mountpoint -q /mnt/persist
      mountpoint -q /mnt/boot

      echo "installer: installing embedded NixOS closure"
      ${pkgs.nixos-install-tools}/bin/nixos-install \
        --root /mnt \
        --system ${installer.targetSystem} \
        --no-root-passwd

      sync
      echo "installer: installation complete; rebooting"
      ${pkgs.systemd}/bin/systemctl reboot
    '';
  };
}
