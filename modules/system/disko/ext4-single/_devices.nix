{
  lib,
  device,
  swapSize ? "0G",
}:
let
  hasSwap = swapSize != "0G" && swapSize != "0" && swapSize != "";
in
{
  disk.main = {
    inherit device;
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          type = "EF00";
          size = "500M";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
      }
      // lib.optionalAttrs hasSwap {
        swap = {
          size = swapSize;
          content = {
            type = "swap";
            resumeDevice = false;
          };
        };
      }
      // {
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
            mountOptions = [
              "noatime"
            ];
          };
        };
      };
    };
  };
}
