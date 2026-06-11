_: {
  virtualisation.docker.enable = true;
  virtualisation.docker.storageDriver = "btrfs";

  environment.persistence."/persist/system" = {
    directories = [
      "/var/lib/docker"
    ];
  };
}
