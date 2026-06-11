{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.cluster.autoUpgrade;
in
{
  options.cluster.autoUpgrade = {
    enable = mkEnableOption "pull-based auto-upgrade timer";
    cacheBaseUrl = mkOption {
      type = types.str;
      default = "https://cache.cluster.local";
    };
    onCalendar = mkOption {
      type = types.str;
      default = "*-*-* 04:30:00";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.cluster-auto-upgrade = {
      description = "Pull latest role closure from cluster cache";
      path = with pkgs; [
        curl
        nix
      ];
      serviceConfig.Type = "oneshot";
      script = ''
        set -eu
        role="${config.cluster.role.name}"
        sys="$(nix eval --raw --impure --expr 'builtins.currentSystem')"
        target="$(curl --fail --silent "${cfg.cacheBaseUrl}/role/$role/$sys/latest" || true)"
        [ -z "$target" ] && { echo "empty pointer, skip"; exit 0; }
        cur="$(readlink -f /run/current-system || true)"
        [ "$cur" = "$target" ] && { echo "already at $target"; exit 0; }
        nix-store --realise "$target"
        nix-env --profile /nix/var/nix/profiles/system --set "$target"
        "$target/bin/switch-to-configuration" switch
      '';
    };

    systemd.timers.cluster-auto-upgrade = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        RandomizedDelaySec = "20m";
      };
    };
  };
}
