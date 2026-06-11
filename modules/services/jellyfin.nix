_: {
  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };

  environment.persistence."/persist/system".directories = [
    {
      directory = "/var/lib/jellyfin";
      user = "jellyfin";
      group = "jellyfin";
      mode = "0700";
    }
  ];
}
