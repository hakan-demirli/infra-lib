{
  logicalCpus =
    hardware:
    if hardware.cpu_logical_count != null then
      hardware.cpu_logical_count
    else
      hardware.cpu_sockets * hardware.cpu_cores_per_socket * hardware.cpu_threads_per_core;
}
