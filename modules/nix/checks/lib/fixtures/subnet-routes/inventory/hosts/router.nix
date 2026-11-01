{
  id = "router";
  topology_roles = [ "external" ];
  state = "provisioned";
  location.kind = "network-equipment";
  ownership = {
    class = "personal";
    owner = "owner";
  };
  hardware = {
    cpu_vendor = "mediatek";
    cpu_sockets = 1;
    cpu_cores_per_socket = 4;
    cpu_threads_per_core = 1;
    ram_mib = 1024;
    arch = "aarch64-linux";
    os = "openwrt";
  };
}
