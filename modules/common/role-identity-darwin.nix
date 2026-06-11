{
  lib,
  config,
  host ? null,
  cluster ? null,
  ...
}:
with lib;
let
  ownerId = if host == null then null else (host.ownership.owner or null);
  ownerUser = if ownerId == null || cluster == null then null else (cluster.users.${ownerId} or null);
  ownerUsername =
    if ownerUser == null || ownerUser.system_account == null then
      null
    else
      ownerUser.system_account.username;
in
{
  options.cluster = {
    host = mkOption {
      type = types.attrsOf types.anything;
      default = { };
    };
    role.name = mkOption {
      type = types.str;
      default = "(unknown)";
    };
    role.tunables = mkOption {
      type = types.attrsOf types.anything;
      default = { };
    };
  };

  config = mkMerge [
    {
      networking.hostName = mkDefault (config.cluster.host.id or "unknown");
      system.stateVersion = mkDefault 5;

      cluster.role.name = mkDefault (
        if config.cluster.host ? roles && config.cluster.host.roles != [ ] then
          head config.cluster.host.roles
        else
          "(unknown)"
      );
      cluster.role.tunables = mkDefault (config.cluster.host.tunables or { });
    }
    (mkIf (ownerUsername != null) {
      system.primaryUser = mkDefault ownerUsername;
    })
  ];
}
