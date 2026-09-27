{
  config,
  lib,
  host,
  ...
}:
let
  vendor = host.hardware.cpu_vendor;
  firmware = config.hardware.enableRedistributableFirmware;
in
{
  hardware.cpu = {
    amd.updateMicrocode = lib.mkIf (vendor == "amd") (lib.mkDefault firmware);
    intel.updateMicrocode = lib.mkIf (vendor == "intel") (lib.mkDefault firmware);
  };
}
