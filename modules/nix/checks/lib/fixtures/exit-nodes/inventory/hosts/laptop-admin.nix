{
  id = "laptop-admin";
  deployment_roles = [ "tailnet-node" ];
  topology_roles = [ "admin-client" ];
  state = "provisioned";
  location.kind = "laptop";
  ownership = {
    class = "personal";
    owner = "owner";
  };
  hardware = {
    arch = "x86_64-linux";
    cpu_vendor = "intel";
    cpu_sockets = 1;
    cpu_cores_per_socket = 2;
    cpu_threads_per_core = 1;
    ram_mib = 2048;
  };
}
