{ pkgs, self }:
let
  inherit (pkgs) lib;
  expectedDisk = "/dev/disk/by-id/test-installer-disk";
  targetSystem = pkgs.runCommand "installer-target-system" { } ''
    mkdir -p "$out"
    touch "$out/init"
  '';
  diskoScript = pkgs.writeShellScript "installer-disko" ''
    exit 0
  '';
  bundle = self.lib.mkDiskoInstallerBundle {
    inherit (self) inputs;
    inherit diskoScript expectedDisk targetSystem;
    system = pkgs.stdenv.hostPlatform.system;
    hostId = "test-installer";
    rootKeys = [ "ssh-ed25519 AAAA-test-installer-key test@installer" ];
  };
  script = builtins.unsafeDiscardStringContext bundle.installScript;
  diskoScriptPath = builtins.unsafeDiscardStringContext "${diskoScript}";
  targetSystemPath = builtins.unsafeDiscardStringContext "${targetSystem}";
  targetArchivePath = builtins.baseNameOf targetSystemPath;
  squashfsMountUnit = "sysroot-nix-.ro\\x2dstore.mount";

  checks = {
    exact-disk-is-exposed = bundle.expectedDisk == expectedDisk;
    target-system-is-embedded = bundle.targetSystem == targetSystem;
    disko-script-is-embedded = bundle.diskoScript == diskoScript;
    kernel-marker-is-host-scoped = bundle.kernelMarker == "infra.install=test-installer";
    initrd-uses-staged-squashfs = bundle.initrdMode == "staged-squashfs";
    assembly-gates-squashfs-mount = bundle.assemblyRequiredBy == [ squashfsMountUnit ];
    assembly-does-not-restart = bundle.assemblyRemainAfterExit;
    assembly-verifies-size-and-hash =
      lib.hasInfix "SquashFS size mismatch" bundle.assemblyScript
      && lib.hasInfix "SquashFS hash mismatch" bundle.assemblyScript;
    runtime-checks-stable-disk = lib.hasInfix "expected_disk=/dev/disk/by-id/test-installer-disk" script;
    runtime-checks-whole-disk = lib.hasInfix "lsblk -dn -o TYPE" script;
    runtime-runs-disko = lib.hasInfix diskoScriptPath script;
    runtime-installs-embedded-closure =
      lib.hasInfix "--system ${targetSystemPath}" script && lib.hasInfix "--no-root-passwd" script;
    runtime-checks-required-mounts = lib.all (path: lib.hasInfix "mountpoint -q ${path}" script) [
      "/mnt"
      "/mnt/nix"
      "/mnt/persist"
      "/mnt/boot"
    ];
    runtime-preserves-no-old-state =
      !lib.hasInfix "NetworkManager" script
      && !lib.hasInfix "tailscale" script
      && !lib.hasInfix "root_vg" script
      && !lib.hasInfix "/persist/install-source" script;
    runtime-reboots-only-after-install =
      lib.hasInfix "nixos-install" script && lib.hasInfix "installation complete; rebooting" script;
  };
  failures = lib.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
pkgs.runCommand "disko-installer-contract"
  {
    bundlePath = bundle;
    manifestPath = bundle.squashfsManifest;
    squashfsPath = bundle.installerSquashfs;
    inherit targetArchivePath;
    failureCount = toString (lib.length failures);
    failureNames = lib.concatStringsSep "," failures;
  }
  ''
    set -euo pipefail
    test -x "$bundlePath"
    test -s "$squashfsPath"
    test "$(<"$manifestPath/size")" = "$(stat -c %s "$squashfsPath")"
    test "$(<"$manifestPath/sha256")" = "$(sha256sum "$squashfsPath" | cut -d ' ' -f 1)"
    ${pkgs.gnugrep}/bin/grep -F "staging SquashFS" "$bundlePath"
    ${pkgs.gnugrep}/bin/grep -F "infra.payload-device=" "$bundlePath"
    ${pkgs.squashfsTools}/bin/unsquashfs -ll "$squashfsPath" \
      | ${pkgs.gnugrep}/bin/grep -F "/$targetArchivePath"
    if [ "$failureCount" != 0 ]; then
      echo "failed Disko installer contracts: $failureNames" >&2
      exit 1
    fi
    touch "$out"
  ''
