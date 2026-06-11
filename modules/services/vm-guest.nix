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
in
{
  config = lib.mkIf isGuest {
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
      {
        assertion = virt.image != null && virt.cpus != null && virt.ram_gb != null && virt.disk_gb != null;
        message = "vm-guest: image, cpus, ram_gb, and disk_gb must all be declared.";
      }
      {
        assertion = !virt.enable && virt.pool_path == null && virt.bridge == null && virt.images == { };
        message = "vm-guest: guest inventory cannot declare virt-host payload.";
      }
    ];
  };
}
