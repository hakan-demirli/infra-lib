{
  config,
  lib,
  pkgs,
  host,
  cluster,
  ...
}:
let
  ports = import ../lib/exporter-ports.nix;
  monitoringEnabled =
    (host.monitoring.enabled or true) && (lib.elem "node" (host.monitoring.exporters or [ "node" ]));
  metricsDirectory = "/var/lib/prometheus-node-exporter-textfiles";
  ownerId = host.ownership.owner or null;
  ownerAccount = if ownerId == null then null else cluster.users.${ownerId}.system_account;
  ownerManagerMonitored = ownerAccount != null && config.users.users ? ${ownerAccount.username};
  userUnitCollector = pkgs.writeShellApplication {
    name = "collect-fleet-user-units";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.util-linux
      config.systemd.package
    ];
    text = ''
      mkdir -p ${metricsDirectory}
      output="$(mktemp ${metricsDirectory}/fleet-user-units.prom.XXXXXX)"
      trap 'rm -f "$output"' EXIT

      {
        printf '%s\n' '# HELP fleet_user_systemd_unit_failed Failed unit in the systemd user manager of the host owner.'
        printf '%s\n' '# TYPE fleet_user_systemd_unit_failed gauge'
        if systemctl is-active --quiet user@${toString ownerAccount.uid}.service; then
          setpriv \
            --reuid=${ownerAccount.username} \
            --regid=${config.users.users.${ownerAccount.username}.group} \
            --clear-groups \
            env XDG_RUNTIME_DIR=/run/user/${toString ownerAccount.uid} \
            systemctl --user list-units --state=failed --output=json \
            | jq -r \
              --arg host ${lib.escapeShellArg host.id} \
              --arg user ${ownerAccount.username} \
              '.[] | "fleet_user_systemd_unit_failed{host=\($host | tojson),user=\($user | tojson),name=\(.unit | tojson)} 1"'
        fi
      } > "$output"

      chmod 0644 "$output"
      mv "$output" ${metricsDirectory}/fleet-user-units.prom
      trap - EXIT
    '';
  };
  revisionCollector = pkgs.writeShellApplication {
    name = "collect-fleet-revisions";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
    ];
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
      systemActivatedAt="$(stat -c %Y /run/current-system)"

      bootComponentChanged() {
        local component=$1
        if [[ $component == kernel-params ]]; then
          if cmp -s "/run/booted-system/$component" "/run/current-system/$component"; then
            return 1
          fi
        else
          [[ "$(readlink -f "/run/booted-system/$component")" != "$(readlink -f "/run/current-system/$component")" ]]
        fi
      }

      {
        printf '%s\n' '# HELP fleet_nixos_system_info Active NixOS system generation and source revision.'
        printf '%s\n' '# TYPE fleet_nixos_system_info gauge'
        printf 'fleet_nixos_system_info{host="%s",generation="%s",revision="%s",revision_kind="%s",version="%s",closure="%s"} 1\n' \
          ${lib.escapeShellArg host.id} "$systemGeneration" "$systemRevision" "$systemRevisionKind" "$systemVersion" "$systemClosure"
        printf '%s\n' '# HELP fleet_nixos_system_activation_timestamp_seconds When the active NixOS generation was activated.'
        printf '%s\n' '# TYPE fleet_nixos_system_activation_timestamp_seconds gauge'
        printf 'fleet_nixos_system_activation_timestamp_seconds{host="%s"} %s\n' \
          ${lib.escapeShellArg host.id} "$systemActivatedAt"
        printf '%s\n' '# HELP fleet_nixos_reboot_required Boot component of the active generation that only takes effect after a reboot.'
        printf '%s\n' '# TYPE fleet_nixos_reboot_required gauge'
        for component in kernel initrd kernel-modules kernel-params; do
          required=0
          if bootComponentChanged "$component"; then
            required=1
          fi
          printf 'fleet_nixos_reboot_required{host="%s",component="%s"} %s\n' \
            ${lib.escapeShellArg host.id} "$component" "$required"
        done
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
  imports = [ ./tailnet-only-ports.nix ];

  config = lib.mkIf monitoringEnabled {
    services.prometheus.exporters.node = {
      enable = true;
      port = ports.node;
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

      services = {
        fleet-revision-metrics = {
          description = "Export active NixOS and Home Manager revisions";
          wantedBy = [ "multi-user.target" ];
          before = [ "prometheus-node-exporter.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe revisionCollector;
          };
        };

        fleet-user-unit-metrics = lib.mkIf ownerManagerMonitored {
          description = "Export failed units of the host owner's systemd user manager";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe userUnitCollector;
            CapabilityBoundingSet = [
              "CAP_SETUID"
              "CAP_SETGID"
            ];
            InaccessiblePaths = [
              "/home"
              "/root"
            ];
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectSystem = "strict";
            ReadWritePaths = [ metricsDirectory ];
          };
        };
      };

      timers = {
        fleet-revision-metrics = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "1m";
            OnUnitActiveSec = "5m";
            Unit = "fleet-revision-metrics.service";
          };
        };

        fleet-user-unit-metrics = lib.mkIf ownerManagerMonitored {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "1m";
            OnUnitActiveSec = "5m";
            Unit = "fleet-user-unit-metrics.service";
          };
        };
      };
    };

    cluster.firewall.tailnetOnlyTCPPorts = [ ports.node ];
  };
}
