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
          size = "1G";
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
            resumeDevice = true;
          };
        };
      }
      // {
        zfs = {
          size = "100%";
          content = {
            type = "zfs";
            pool = "rpool";
          };
        };
      };
    };
  };

  zpool.rpool = {
    type = "zpool";
    mode = "";
    rootFsOptions = {
      acltype = "posixacl";
      atime = "off";
      canmount = "off";
      compression = "zstd";
      dnodesize = "auto";
      mountpoint = "none";
      normalization = "formD";
      relatime = "on";
      "com.sun:auto-snapshot" = "false";
    };
    options = {
      ashift = "12";
      autotrim = "on";
    };
    datasets = {
      "local" = {
        type = "zfs_fs";
        options.mountpoint = "none";
      };
      "local/root" = {
        type = "zfs_fs";
        mountpoint = "/";
        options.mountpoint = "legacy";
      };
      "local/nix" = {
        type = "zfs_fs";
        mountpoint = "/nix";
        options.mountpoint = "legacy";
      };
      "local/var" = {
        type = "zfs_fs";
        mountpoint = "/var";
        options.mountpoint = "legacy";
      };
      "safe" = {
        type = "zfs_fs";
        options.mountpoint = "none";
      };
      "safe/persist" = {
        type = "zfs_fs";
        mountpoint = "/persist";
        options = {
          mountpoint = "legacy";
          "com.sun:auto-snapshot" = "true";
        };
      };
      "safe/home" = {
        type = "zfs_fs";
        mountpoint = "/home";
        options.mountpoint = "legacy";
      };
      "reserved" = {
        type = "zfs_fs";
        options = {
          mountpoint = "none";
          refreservation = "1G";
        };
      };
    };
  };
}
