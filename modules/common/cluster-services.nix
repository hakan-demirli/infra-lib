{
  config,
  lib,
  cluster ? null,
  host ? null,
  ...
}:
let
  served =
    if cluster == null || host == null then
      { }
    else
      lib.filterAttrs (_: s: lib.elem host.id s.hosts) cluster.services;

  service = lib.types.submodule {
    options = {
      port = lib.mkOption { type = lib.types.port; };
      role = lib.mkOption { type = lib.types.str; };
      cluster = lib.mkOption { type = lib.types.str; };
      clients = lib.mkOption { type = lib.types.listOf lib.types.str; };
      hosts = lib.mkOption { type = lib.types.listOf lib.types.str; };
      firewall = lib.mkOption {
        type = lib.types.enum [
          "tailnet-only"
          "public"
        ];
        default = "tailnet-only";
      };
    };
  };
in
{
  imports = [ ./tailnet-only-ports.nix ];

  options.cluster.services = lib.mkOption {
    type = lib.types.attrsOf service;
    readOnly = true;
    description = "Inventory cluster services that this host serves. Their TCP ports open only on the tailnet unless the service is public.";
  };

  config = {
    cluster.services = served;
    cluster.firewall.tailnetOnlyTCPPorts = lib.mapAttrsToList (_: s: s.port) (
      lib.filterAttrs (_: s: s.firewall == "tailnet-only") config.cluster.services
    );
  };
}
