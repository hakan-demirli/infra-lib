{
  id = "vps";
  deployment_roles = [ "tailnet-node" ];
  topology_roles = [ "controller" ];
  state = "provisioned";
  location = {
    kind = "cloud-vm";
    provider = "test";
  };
  ownership = {
    class = "personal";
    owner = "owner";
  };
  hardware = {
    arch = "x86_64-linux";
    cpu_vendor = "amd";
    cpu_sockets = 1;
    cpu_cores_per_socket = 2;
    cpu_threads_per_core = 1;
    ram_mib = 2048;
  };
  tailnet_exit_node = true;
}
