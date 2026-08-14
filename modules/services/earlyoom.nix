_: {
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 10;
    freeSwapThreshold = 10;
    freeMemKillThreshold = 5;
    freeSwapKillThreshold = 5;
    enableNotifications = false;
    extraArgs = [
      "-g"
      "--sort-by-rss"
      "--avoid"
      "^(kitty|ssh|sshd|tmux.*|systemd|systemd-logind|[(]sd-pam[)]|sddm|Hyprland|Xorg|waybar|pipewire-pulse|wireplumber|scrd|dbus-daemon|dbus-broker.*|gpg-agent|ssh-agent)$"
      "--prefer"
      "^(electron|chrom|java|node|cc1plus|rustc|cargo|gcc)$"
    ];
  };
}
