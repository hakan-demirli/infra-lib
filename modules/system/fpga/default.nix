{
  config,
  lib,
  ...
}:
let
  cfg = config.hardware.fpga;
  devices = lib.attrValues cfg.devices;
  pciAddresses = map (device: device.pciAddress) devices;
in
{
  imports = [ ./amd-alveo-v80.nix ];

  options.hardware.fpga = {
    enable = lib.mkEnableOption "FPGA devices";

    devices = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            kind = lib.mkOption {
              type = lib.types.enum [ "amd-alveo-v80" ];
              description = "FPGA model and software-stack selector.";
            };

            pciAddress = lib.mkOption {
              type = lib.types.strMatching "^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\\.[0-7]$";
              description = "PCI address of the FPGA management function.";
            };

            parentPciAddress = lib.mkOption {
              type = lib.types.strMatching "^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\\.[0-7]$";
              description = "PCI address of the root port that owns the FPGA.";
            };
          };
        }
      );
      default = { };
      description = "FPGA devices managed by this host.";
    };
  };

  config.assertions = [
    {
      assertion = cfg.enable == (cfg.devices != { });
      message = "hardware.fpga.enable must be true exactly when hardware.fpga.devices is non-empty.";
    }
    {
      assertion = lib.length pciAddresses == lib.length (lib.unique pciAddresses);
      message = "hardware.fpga.devices contains duplicate PCI addresses.";
    }
  ];
}
