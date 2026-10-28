{ config, lib, ... }:
let
  cfg = config.services.reverse-ssh-server;
in
{
  imports = [ ../common/tailnet-only-ports.nix ];

  options.services.reverse-ssh-server = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable reverse SSH tunnel server (gateway ports)";
    };
    allowedTCPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.int;
      default = [ ];
      description = "TCP ports to allow in firewall";
    };
    tailnetOnly = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open allowedTCPPorts only on the tailnet interface instead of every interface.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.enable || cfg.allowedTCPPorts == [ ];
          message = "services.reverse-ssh-server.allowedTCPPorts requires enable=true.";
        }
        {
          assertion = lib.all (port: port > 0 && port <= 65535) cfg.allowedTCPPorts;
          message = "services.reverse-ssh-server.allowedTCPPorts contains an invalid TCP port.";
        }
      ];
    }

    (lib.mkIf cfg.enable {
      services.openssh.settings = {
        GatewayPorts = "clientspecified";
        AllowTcpForwarding = true;
      };

      networking.firewall = {
        enable = true;
        allowedTCPPorts = lib.mkIf (!cfg.tailnetOnly) cfg.allowedTCPPorts;
      };

      cluster.firewall.tailnetOnlyTCPPorts = lib.mkIf cfg.tailnetOnly cfg.allowedTCPPorts;
    })
  ];
}
