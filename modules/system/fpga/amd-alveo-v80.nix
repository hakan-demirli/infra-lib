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
  backend = config.hardware.fpga.amdAlveoV80;
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
  options.hardware.fpga.amdAlveoV80 = {
    autoLoad = lib.mkEnableOption "automatic AMI loading during boot";
    heartbeat = lib.mkEnableOption "periodic AMI-to-AMC heartbeat requests";
    logging = lib.mkEnableOption "continuous AMC firmware log polling";
  };

  config = lib.mkIf enabled {
    boot = {
      blacklistedKernelModules = [ "ami" ];
      extraModprobeConfig = ''
        options ami heartbeat=${if backend.heartbeat then "1" else "0"} logging=${
          if backend.logging then "1" else "0"
        }
      '';
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
        wantedBy = lib.optional backend.autoLoad "multi-user.target";
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
          already_ready=1
          for bdf in ${lib.escapeShellArgs (map (device: device.pciAddress) devices)}; do
            device="/sys/bus/pci/devices/$bdf"
            driver=
            state=
            if [[ -L "$device/driver" ]]; then
              driver="$(basename "$(readlink -f "$device/driver")")"
            fi
            if [[ -r "$device/dev_state" ]]; then
              state="$(<"$device/dev_state")"
            fi
            if [[ "$driver" != ami || "$state" != READY ]]; then
              already_ready=0
            fi
          done
          for bdf in ${lib.escapeShellArgs (map (device: device.pciAddress) devices)}; do
            config_path="/sys/bus/pci/devices/$bdf/config"
            vsec=
            valid_samples=0
            for ((attempt = 1; attempt <= 120; attempt++)); do
              vsec=
              if [[ -r "$config_path" ]]; then
                vsec="$(od -A n -t x4 -j 1536 -N 4 "$config_path" 2>/dev/null | tr -d ' \n')"
              fi
              if [[ "$vsec" == 0001000b ]]; then
                ((valid_samples += 1))
              fi
              printf 'V80 %s VSEC sample %d: 0x%s (valid %d/10)\n' \
                "$bdf" "$attempt" "$vsec" "$valid_samples"
              if ((valid_samples == 10)); then
                break
              fi
              sleep 0.5
            done
            if ((valid_samples != 10)); then
              printf 'V80 %s did not expose VSEC 0x0001000b ten times\n' "$bdf" >&2
              exit 1
            fi
          done

          if ((already_ready)); then
            printf 'All configured V80 devices have stable VSEC and are bound to AMI in READY state\n'
            exit 0
          fi

          modprobe ami

          for bdf in ${lib.escapeShellArgs (map (device: device.pciAddress) devices)}; do
            device="/sys/bus/pci/devices/$bdf"
            driver=
            state=
            if [[ -L "$device/driver" ]]; then
              driver="$(basename "$(readlink -f "$device/driver")")"
            fi
            if [[ -r "$device/dev_state" ]]; then
              state="$(<"$device/dev_state")"
            fi
            printf 'V80 %s AMI probe result: driver=%s state=%s\n' "$bdf" "$driver" "$state"
            if [[ "$driver" != ami || "$state" != READY ]]; then
              printf 'AMI did not bring V80 %s to READY\n' "$bdf" >&2
              exit 1
            fi
          done
        '';
      };
    };
  };
}
