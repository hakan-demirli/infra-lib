{
  config,
  lib,
  pkgs,
  ...
}:
let
  devices = lib.attrValues (
    lib.filterAttrs (_: device: device.kind == "amd-alveo-v80") config.hardware.fpga.devices
  );
  enabled = config.hardware.fpga.enable && devices != [ ];
  bdfs = lib.unique (
    lib.concatMap (device: [
      device.parentPciAddress
      device.pciAddress
    ]) devices
  );
  ami = pkgs.callPackage ./amd-alveo-v80/ami/package.nix {
    inherit (config.boot.kernelPackages) kernel;
  };
in
{
  config = lib.mkIf enabled {
    boot = {
      blacklistedKernelModules = [ "ami" ];
      extraModulePackages = [ ami ];
    };

    environment.systemPackages = [
      ami
      pkgs.pciutils
    ];

    services.udev.extraRules = lib.concatMapStringsSep "\n" (device: ''
      ACTION=="add", SUBSYSTEM=="pci", KERNEL=="${device.parentPciAddress}", ATTR{d3cold_allowed}="0", ATTR{power/control}="on"
      ACTION=="add", SUBSYSTEM=="pci", KERNEL=="${device.pciAddress}", ATTR{d3cold_allowed}="0", ATTR{power/control}="on"
    '') devices;

    systemd.services = {
      systemd-modules-load = {
        after = [ "fpga-v80-power-guard.service" ];
        requires = [ "fpga-v80-power-guard.service" ];
      };

      fpga-v80-power-guard = {
        description = "Disable D3cold before loading the Alveo V80 AMI driver";
        wantedBy = [ "sysinit.target" ];
        before = [
          "systemd-modules-load.service"
          "sysinit.target"
        ];
        after = [ "local-fs.target" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          for bdf in ${lib.escapeShellArgs bdfs}; do
            device="/sys/bus/pci/devices/$bdf"
            if [[ -w "$device/d3cold_allowed" ]]; then
              printf '0\n' > "$device/d3cold_allowed"
            fi
            if [[ -w "$device/power/control" ]]; then
              printf 'on\n' > "$device/power/control"
            fi
          done
        '';
      };

      fpga-v80-ami = {
        description = "Load AMI after the Alveo V80 management interface is ready";
        wantedBy = [ "multi-user.target" ];
        after = [ "fpga-v80-power-guard.service" ];
        requires = [ "fpga-v80-power-guard.service" ];
        path = [
          pkgs.coreutils
          pkgs.kmod
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          for bdf in ${lib.escapeShellArgs (map (device: device.pciAddress) devices)}; do
            config_path="/sys/bus/pci/devices/$bdf/config"
            vsec=
            for ((attempt = 0; attempt < 60; attempt++)); do
              if [[ -r "$config_path" ]]; then
                vsec="$(od -A n -t x4 -j 1536 -N 4 "$config_path" 2>/dev/null | tr -d ' \n')"
              fi
              if [[ "$vsec" == 0001000b ]]; then
                break
              fi
              sleep 1
            done
            if [[ "$vsec" != 0001000b ]]; then
              printf 'V80 %s did not expose VSEC 0x0001000b (got 0x%s)\n' "$bdf" "$vsec" >&2
              exit 1
            fi
          done

          sleep 2
          modprobe ami

          for bdf in ${lib.escapeShellArgs (map (device: device.pciAddress) devices)}; do
            driver="$(basename "$(readlink -f "/sys/bus/pci/devices/$bdf/driver")")"
            if [[ "$driver" != ami ]]; then
              printf 'AMI did not bind V80 %s\n' "$bdf" >&2
              exit 1
            fi
          done
        '';
      };
    };
  };
}
