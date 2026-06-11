{ pkgs, ... }:
{
  boot.initrd.kernelModules = [ "xe" ];

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      intel-media-driver
      intel-compute-runtime
      vpl-gpu-rt
    ];
    extraPackages32 = with pkgs.driversi686Linux; [
      intel-media-driver
    ];
  };

  environment = {
    sessionVariables.LIBVA_DRIVER_NAME = "iHD";
    systemPackages = with pkgs; [
      nvtopPackages.intel
      libva-utils
    ];
  };
}
