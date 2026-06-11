{
  lib,
  host ? null,
  cluster ? null,
  ...
}:
let
  virt = if host == null then null else (host.virt or null);
  isGuest = virt != null && (virt.role or "host") == "guest";
  parentHostId = if host == null then null else (host.location.host or null);
  parent =
    if parentHostId == null || cluster == null then null else (cluster.hosts.${parentHostId} or null);
  parentVirt = if parent == null then null else (parent.virt or null);
  imageKey = if virt == null then null else (virt.image or null);
  parentImage =
    if parentVirt == null || imageKey == null then null else (parentVirt.images.${imageKey} or null);
  active = isGuest && parentImage != null;
in
{
  config = lib.mkIf active {
    assertions = [
      {
        assertion = parent != null;
        message = "vm-guest: host.location.host is null or unknown for guest '${host.id}'.";
      }
      {
        assertion = parentVirt != null && parentVirt.enable;
        message = "vm-guest: parent host '${parentHostId}' does not have virt.enable = true.";
      }
      {
        assertion = parentImage != null;
        message = "vm-guest: image '${toString imageKey}' is not in parent '${parentHostId}'.virt.images.";
      }
    ];
  };
}
