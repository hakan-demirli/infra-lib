_: {
  services.fail2ban = {
    enable = true;

    bantime = "4h";

    bantime-increment = {
      enable = true;
      multipliers = "1 2 4 8 16 32 64";
      maxtime = "168h";
    };

    jails = {
      sshd = {
        settings = {
          enable = true;
          backend = "systemd";
          maxretry = 2;
          findtime = "60m";
        };
      };
    };
  };
}
