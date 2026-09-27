{
  lib,
  pkgs,
  config,
  host,
  cluster,
  ...
}:
let
  cfg = config.cluster.autoUpgrade;
  defaultOnCalendar = "*-*-* 04..06:00/10:00";
  metricsDirectory = "/var/lib/prometheus-node-exporter-textfiles";
  stateDirectory = "/var/lib/fleet-upgrade";
  inPlan =
    host != null
    && cluster != null
    && cluster.deployController != null
    && lib.elem host.id cluster.deployableHosts
    && (host.monitoring.enabled or true);
  healthUnits =
    lib.optional config.services.openssh.enable "sshd.service"
    ++ lib.optional config.services.tailscale.enable "tailscaled.service";
  refreshRevisionMetrics = lib.optionalString (config.systemd.services ? fleet-revision-metrics) ''
    systemctl start --no-block fleet-revision-metrics.service
  '';

  upgrade = pkgs.writeShellApplication {
    name = "fleet-upgrade";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      pkgs.util-linux
      config.nix.package
      config.systemd.package
    ];
    text = ''
      host=${lib.escapeShellArg (if host == null then "" else host.id)}
      plan_url=${lib.escapeShellArg (if cfg.planUrl == null then "" else cfg.planUrl)}
      flake=${lib.escapeShellArg (if cfg.flake == null then "" else cfg.flake)}
      metrics=${metricsDirectory}/fleet-upgrade.prom
      failed_marker=${stateDirectory}/failed-toplevel

      state=failed
      reason=internal
      target_revision=
      last_success="$(sed -n 's/^fleet_upgrade_last_success_timestamp_seconds{[^}]*} //p' "$metrics" 2>/dev/null || true)"
      [[ $last_success =~ ^[0-9]+$ ]] || last_success="$(date +%s)"

      report() {
        local output
        mkdir -p ${metricsDirectory}
        output="$(mktemp ${metricsDirectory}/fleet-upgrade.prom.XXXXXX)"
        [[ $state != current ]] || last_success="$(date +%s)"
        {
          printf '%s\n' '# HELP fleet_upgrade_state Outcome of the latest fleet upgrade run.'
          printf '%s\n' '# TYPE fleet_upgrade_state gauge'
          printf 'fleet_upgrade_state{host="%s",state="%s",reason="%s",revision="%s"} 1\n' \
            "$host" "$state" "$reason" "$target_revision"
          printf '%s\n' '# HELP fleet_upgrade_last_run_timestamp_seconds Time of the latest fleet upgrade run.'
          printf '%s\n' '# TYPE fleet_upgrade_last_run_timestamp_seconds gauge'
          printf 'fleet_upgrade_last_run_timestamp_seconds{host="%s"} %s\n' "$host" "$(date +%s)"
          printf '%s\n' '# HELP fleet_upgrade_last_success_timestamp_seconds Time the host last ran its planned generation.'
          printf '%s\n' '# TYPE fleet_upgrade_last_success_timestamp_seconds gauge'
          printf 'fleet_upgrade_last_success_timestamp_seconds{host="%s"} %s\n' "$host" "$last_success"
        } > "$output"
        chmod 0644 "$output"
        mv -f "$output" "$metrics"
      }

      finish() {
        state=$1
        reason=$2
        echo "fleet-upgrade: $state ($reason)''${target_revision:+ revision $target_revision}"
        report
        if [[ $state == failed ]]; then
          exit 1
        fi
        exit 0
      }

      reachable() {
        ${
          lib.optionalString (healthUnits != [ ]) ''
            systemctl is-active --quiet ${lib.escapeShellArgs healthUnits} || return 1
          ''
        }curl -fsS --connect-timeout 5 --max-time 15 -o /dev/null "$plan_url"
      }

      settled() {
        local attempt
        for ((attempt = 1; attempt <= ${toString cfg.healthAttempts}; attempt++)); do
          reachable && return 0
          sleep 5
        done
        return 1
      }

      exec {lock}>/run/fleet-upgrade.lock
      flock -n "$lock" || { echo "fleet-upgrade: another run is active"; exit 0; }

      if ! plan="$(curl -fsS --connect-timeout 10 --max-time 60 "$plan_url")"; then
        finish offline plan-unreachable
      fi
      if ! jq -e '(.hosts | type == "object") and (.history | type == "array")' <<< "$plan" > /dev/null 2>&1; then
        finish failed invalid-plan
      fi

      revision="$(/run/current-system/sw/bin/nixos-version --configuration-revision 2>/dev/null || true)"
      if [[ ! $revision =~ ^[0-9a-f]{40}$ ]] || ! jq -e --arg revision "$revision" '.history | index([$revision]) != null' <<< "$plan" > /dev/null; then
        finish held local
      fi

      if ! entry="$(jq -ce --arg host "$host" '.hosts[$host] // empty' <<< "$plan")"; then
        finish waiting not-planned
      fi
      target_revision="$(jq -r '.revision // ""' <<< "$entry")"
      case "$(jq -r '.state' <<< "$entry")" in
        planned) ;;
        held) finish held inventory ;;
        *) finish waiting "$(jq -r '.reason // "gate"' <<< "$entry")" ;;
      esac

      toplevel="$(jq -r '.toplevel // ""' <<< "$entry")"
      if [[ ! $target_revision =~ ^[0-9a-f]{40}$ ]] \
        || [[ ! $toplevel =~ ^/nix/store/[0-9a-z]{32}-nixos-system-"$host"-[^/]+$ ]]; then
        finish failed invalid-plan
      fi
      if [[ "$(readlink -f /run/current-system)" == "$(readlink -f "$toplevel" 2>/dev/null || true)" ]]; then
        rm -f "$failed_marker"
        finish current none
      fi
      if [[ -s $failed_marker ]]; then
        read -r failed_toplevel failed_reason < "$failed_marker"
        if [[ $failed_toplevel == "$toplevel" ]]; then
          finish failed "$failed_reason"
        fi
      fi

      if ! built="$(nix build --no-link --print-out-paths \
        "$flake?rev=$target_revision#nixosConfigurations.\"$host\".config.system.build.toplevel")"; then
        finish failed build
      fi
      if [[ $built != "$toplevel" ]]; then
        finish failed mismatch
      fi
      previous="$(readlink -f /run/current-system)"
      if ! nix-env --profile /nix/var/nix/profiles/system --set "$toplevel"; then
        finish failed profile
      fi
      if ! "$toplevel/bin/switch-to-configuration" switch; then
        printf '%s switch\n' "$toplevel" > "$failed_marker"
        finish failed switch
      fi
      if ! settled; then
        echo "fleet-upgrade: $toplevel lost connectivity; switching back to $previous" >&2
        printf '%s rollback\n' "$toplevel" > "$failed_marker"
        if ! nix-env --profile /nix/var/nix/profiles/system --set "$previous" \
          || ! "$previous/bin/switch-to-configuration" switch; then
          finish failed rollback-failed
        fi
        ${refreshRevisionMetrics}
        finish failed rollback
      fi
      ${refreshRevisionMetrics}
      finish current none
    '';
  };
in
{
  options.cluster.autoUpgrade = {
    enable = lib.mkEnableOption "pull-based fleet upgrades that switch to the planned generation and never reboot";
    planUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "http://deploy.example:5102/plan.json";
      description = "Deployment plan published by the fleet deploy controller.";
    };
    flake = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[^?]+");
      default = null;
      example = "github:example/fleet";
      description = "Flake reference of the repository without a revision. The host builds the planned revision of it.";
    };
    healthAttempts = lib.mkOption {
      type = lib.types.ints.positive;
      default = 24;
      description = "Checks, 5 seconds apart, that sshd, tailscaled and the plan stay reachable after a switch before it switches back.";
    };
    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = defaultOnCalendar;
      description = "Upgrade window. Every run inside it is idempotent, so hosts that wait for a dependency catch up in the same window.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion =
            cfg.enable
            || (
              cfg.planUrl == null
              && cfg.flake == null
              && cfg.healthAttempts == 24
              && cfg.onCalendar == defaultOnCalendar
            );
          message = "cluster.autoUpgrade payload is configured while enable=false.";
        }
        {
          assertion = !cfg.enable || (cfg.planUrl != null && cfg.flake != null && inPlan);
          message = "cluster.autoUpgrade requires planUrl, flake, a fleet deploy controller, and a provisioned, monitored tailnet host.";
        }
      ];
    }

    (lib.mkIf cfg.enable {
      systemd = {
        services.fleet-upgrade = {
          description = "Switch to the planned fleet generation without rebooting";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          restartIfChanged = false;
          unitConfig = {
            ConditionACPower = true;
            StartLimitIntervalSec = 0;
            X-StopOnRemoval = false;
          };
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe upgrade;
            StateDirectory = "fleet-upgrade";
          };
        };

        timers.fleet-upgrade = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.onCalendar;
            Persistent = true;
            RandomizedDelaySec = "5m";
          };
        };
      };
    })
  ];
}
