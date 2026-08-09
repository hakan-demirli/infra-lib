{
  lib,
  pkgs,
  host,
  ...
}:
let
  monitoringEnabled =
    (host.monitoring.enabled or true) && (lib.elem "node" (host.monitoring.exporters or [ "node" ]));
  metricsDirectory = "/var/lib/prometheus-node-exporter-textfiles";
  revisionCollector = pkgs.writeShellApplication {
    name = "collect-fleet-revisions";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      mkdir -p ${metricsDirectory}
      output="$(mktemp ${metricsDirectory}/fleet-revisions.prom.XXXXXX)"
      trap 'rm -f "$output"' EXIT

      currentSystem="$(readlink -f /run/current-system)"
      systemClosure="''${currentSystem##*/}"
      systemProfile="$(readlink /nix/var/nix/profiles/system 2>/dev/null || true)"
      systemGeneration="unknown"
      if [[ "$systemProfile" == system-*-link ]]; then
        systemGeneration="''${systemProfile#system-}"
        systemGeneration="''${systemGeneration%-link}"
      fi
      systemRevision="$(/run/current-system/sw/bin/nixos-version --configuration-revision 2>/dev/null || true)"
      systemRevision="''${systemRevision:-unknown}"
      case "$systemRevision" in
        sha256-* | *-dirty) systemRevisionKind="local" ;;
        unknown) systemRevisionKind="unknown" ;;
        *) systemRevisionKind="git" ;;
      esac
      systemVersion="$(/run/current-system/sw/bin/nixos-version --short)"

      {
        printf '%s\n' '# HELP fleet_nixos_system_info Active NixOS system generation and source revision.'
        printf '%s\n' '# TYPE fleet_nixos_system_info gauge'
        printf 'fleet_nixos_system_info{host="%s",generation="%s",revision="%s",revision_kind="%s",version="%s",closure="%s"} 1\n' \
          ${lib.escapeShellArg host.id} "$systemGeneration" "$systemRevision" "$systemRevisionKind" "$systemVersion" "$systemClosure"
        printf '%s\n' '# HELP fleet_home_manager_generation_info Active standalone Home Manager generation.'
        printf '%s\n' '# TYPE fleet_home_manager_generation_info gauge'

        for home in /home/*; do
          [[ -d "$home" ]] || continue
          profile="$home/.local/state/nix/profiles/home-manager"
          [[ -e "$profile" ]] || continue

          homeProfile="$(readlink "$profile" 2>/dev/null || true)"
          homeGeneration="unknown"
          if [[ "$homeProfile" == home-manager-*-link ]]; then
            homeGeneration="''${homeProfile#home-manager-}"
            homeGeneration="''${homeGeneration%-link}"
          fi
          homeClosure="$(readlink -f "$profile")"
          homeClosure="''${homeClosure##*/}"
          user="''${home##*/}"
          printf 'fleet_home_manager_generation_info{host="%s",user="%s",generation="%s",closure="%s"} 1\n' \
            ${lib.escapeShellArg host.id} "$user" "$homeGeneration" "$homeClosure"
        done
      } > "$output"

      chmod 0644 "$output"
      mv "$output" ${metricsDirectory}/fleet-revisions.prom
      trap - EXIT
    '';
  };
in
{
  config = lib.mkIf monitoringEnabled {
    services.prometheus.exporters.node = {
      enable = true;
      port = 9100;
      enabledCollectors = [
        "systemd"
        "processes"
        "logind"
        "interrupts"
        "ksmd"
        "mountstats"
        "network_route"
        "ntp"
        "tcpstat"
        "textfile"
      ];
      disabledCollectors = [
        "wifi"
      ];
      listenAddress = "0.0.0.0";
      extraFlags = [ "--collector.textfile.directory=${metricsDirectory}" ];
    };

    systemd = {
      tmpfiles.rules = [ "d ${metricsDirectory} 0755 root root -" ];

      services.fleet-revision-metrics = {
        description = "Export active NixOS and Home Manager revisions";
        wantedBy = [ "multi-user.target" ];
        before = [ "prometheus-node-exporter.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe revisionCollector;
        };
      };

      timers.fleet-revision-metrics = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1m";
          OnUnitActiveSec = "5m";
          Unit = "fleet-revision-metrics.service";
        };
      };
    };

    networking.firewall.allowedTCPPorts = [ 9100 ];
  };
}
