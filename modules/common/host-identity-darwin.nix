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
  options.cluster.host = mkOption {
    type = types.attrsOf types.anything;
    default = { };
  };

  config = mkMerge [
    {
      networking.hostName = mkDefault (config.cluster.host.id or "unknown");
      system.stateVersion = mkDefault 5;
    }
    (mkIf (ownerUsername != null) {
      system.primaryUser = mkDefault ownerUsername;
    })
  ];
}
