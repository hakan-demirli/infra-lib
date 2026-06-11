{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.transmission-cluster;
in
{
  options.services.transmission-cluster = {
    downloadDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/transmission/Downloads";
    };
    incompleteDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/transmission/Downloads/.incomplete";
    };
    rpcWhitelist = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1,::1";
    };
  };

  config = {
    services.transmission = {
      enable = true;
      package = pkgs.transmission_4;
      openPeerPorts = true;
      openRPCPort = false;
      performanceNetParameters = true;
      settings = {
        rpc-bind-address = "0.0.0.0";
        rpc-port = 9091;
        rpc-host-whitelist-enabled = false;
        rpc-whitelist-enabled = true;
        rpc-whitelist = cfg.rpcWhitelist;
        download-dir = cfg.downloadDir;
        incomplete-dir = cfg.incompleteDir;
        incomplete-dir-enabled = true;
        trash-original-torrent-files = true;
        umask = 2;
        watch-dir-enabled = false;
      };
    };

    environment.persistence."/persist/system".directories = [
      {
        directory = "/var/lib/transmission";
        user = "transmission";
        group = "transmission";
        mode = "0750";
      }
    ];
  };
}
