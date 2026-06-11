{
  lib,
  config,
  host ? null,
  ...
}:
let
  gpu = if host == null then null else (host.hardware.gpu or null);
  hasNvidia = gpu != null && lib.hasInfix "nvidia" gpu;
  hybridAmd = gpu == "amd+nvidia";
  hybridIntel = gpu == "intel+nvidia";
  hybrid = hybridAmd || hybridIntel;

  labels = if host == null then { } else (host.labels or { });
  amdBusId = labels.gpu_amd_bus_id or null;
  intelBusId = labels.gpu_intel_bus_id or null;
  nvidiaBusId = labels.gpu_nvidia_bus_id or null;

  primeOffload =
    if hybridAmd then
      {
        offload.enable = true;
        offload.enableOffloadCmd = true;
        amdgpuBusId = amdBusId;
        inherit nvidiaBusId;
      }
    else if hybridIntel then
      {
        offload.enable = true;
        offload.enableOffloadCmd = true;
        inherit intelBusId nvidiaBusId;
      }
    else
      { };
in
{
  config = lib.mkIf hasNvidia {
    services.xserver.videoDrivers = [ "nvidia" ];

    services.xserver.drivers = [
      {
        name = "displaylink";
        display = false;
      }
    ];

    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };

    hardware.nvidia = {
      modesetting.enable = true;
      powerManagement.enable = true;
      powerManagement.finegrained = lib.mkDefault hybrid;
      open = false;
      package = config.boot.kernelPackages.nvidiaPackages.production;
      prime = lib.mkIf hybrid primeOffload;
    };

    specialisation.disable-nvidia.configuration = {
      environment.etc."specialization".text = "disable-nvidia";

      boot.extraModprobeConfig = ''
        blacklist nouveau
        options nouveau modeset=0
      '';

      services.udev.extraRules = ''
        ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c0330", ATTR{power/control}="auto", ATTR{remove}="1"
        ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c8000", ATTR{power/control}="auto", ATTR{remove}="1"
        ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x040300", ATTR{power/control}="auto", ATTR{remove}="1"
        ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x03[0-9]*", ATTR{power/control}="auto", ATTR{remove}="1"
      '';
      boot.blacklistedKernelModules = [
        "nouveau"
        "nvidia"
        "nvidia_drm"
        "nvidia_modeset"
      ];
    };

    assertions = [
      {
        assertion = !hybridAmd || (amdBusId != null && nvidiaBusId != null);
        message =
          "host '${host.id}' has hardware.gpu=\"amd+nvidia\" but is missing "
          + "labels.gpu_amd_bus_id and/or labels.gpu_nvidia_bus_id. "
          + "Find them with `lspci -k | grep -EA3 '3D|VGA'`; format \"PCI:b:d:f\".";
      }
      {
        assertion = !hybridIntel || (intelBusId != null && nvidiaBusId != null);
        message =
          "host '${host.id}' has hardware.gpu=\"intel+nvidia\" but is missing "
          + "labels.gpu_intel_bus_id and/or labels.gpu_nvidia_bus_id.";
      }
    ];
  };
}
