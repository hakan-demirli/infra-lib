{
  config,
  lib,
  pkgs,
  host,
  ...
}:
let
  cfg = config.services.fleet-deploy-controller;
  stateDirectory = "/var/lib/fleet-deploy";
  metricsDirectory = "/var/lib/prometheus-node-exporter-textfiles";
  historyLength = 1000;
  impermanenceEnabled = host.impermanence.enable or false;
  tailnetInterface = config.services.tailscale.interfaceName;

  gate = pkgs.writeText "fleet-deploy-gate.jq" ''
    ($history | to_entries | map({key: .value, value: .key}) | from_entries) as $index
    | def order($revision): $index[$revision // ""] // ($history | length);
    def set: map({key: ., value: true}) | from_entries;
    ($inventory.hosts | with_entries(select(.value.hold == null or (.value.hold.until != null and $today > .value.hold.until)))) as $active
    | ([$inventory.hosts[].wave] | unique) as $waves
    | reduce range(0; $waves | length) as $i ({approved: $approved, gates: {}};
        ($waves[$i] | tostring) as $wave
        | if $i == 0 then
            .approved[$wave] = (if .approved[$wave].revision == $history[0] then .approved[$wave] else {revision: $history[0], since: $now} end)
            | .gates[$wave] = {state: "current", candidate: null}
          else
            ($waves[$i - 1] | tostring) as $previous
            | (.approved[$wave].revision // null) as $current
            | ([$active | to_entries[] | select((.value.wave | tostring) == $previous and .value.trusted) | .key] | set) as $canaries
            | if ($canaries | length) == 0 then
                .gates[$wave] = {state: "no-canary", candidate: null}
              elif $metrics == null then
                .gates[$wave] = {state: "metrics-unreachable", candidate: null}
              else
                ([$metrics.failed[].node] | set) as $failing
                | [$metrics.running[] | select($canaries[.node] and order(.revision) < order($current))] as $exposed
                | [$exposed[] | select($failing[.node])]
                  + [$metrics.upgrade_failed[] | select($canaries[.node] and order(.revision) < order($current))]
                  + [$metrics.down[] | select($canaries[.node] and order(.revision) < order($current))] as $unhealthy
                | ([$exposed[] | select(($failing[.node] | not) and .value >= $soak) | .revision] | unique | sort_by(order(.)) | first) as $candidate
                | ([$exposed[].revision] | unique | sort_by(order(.)) | first) as $newest
                | if ($unhealthy | length) > 0 then
                    .gates[$wave] = {state: "blocked", candidate: $newest}
                  elif $candidate != null then
                    .approved[$wave] = {revision: $candidate, since: $now}
                    | .gates[$wave] = {state: "passed", candidate: $candidate}
                  elif $newest != null then
                    .gates[$wave] = {state: "soaking", candidate: $newest}
                  else
                    .gates[$wave] = {state: "waiting", candidate: null}
                  end
              end
          end)
    | . as $result
    | $result + {
        hosts: ($inventory.hosts | with_entries(
          .key as $host
          | .value as $spec
          | ($result.approved[$spec.wave | tostring].revision // null) as $revision
          | .value = (
              if $active[$host] == null then
                {state: "held", reason: "inventory", revision: null}
              elif $revision == null then
                {state: "waiting", reason: "gate", revision: null}
              elif $metrics == null and ($spec.after | length) > 0 then
                {state: "waiting", reason: "metrics-unreachable", revision: $revision}
              elif all($spec.after[]; . as $dependency | $active[$dependency] != null and any($metrics.running[]; .node == $dependency and order(.revision) <= order($revision))) then
                {state: "ready", reason: "none", revision: $revision}
              else
                {state: "waiting", reason: "dependency", revision: $revision}
              end
            ) + {wave: $spec.wave, hold: (if $active[$host] == null then $spec.hold else null end), cache: $spec.cache}
        ))
      }
  '';

  controller = pkgs.writeShellApplication {
    name = "fleet-deploy-controller";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.git
      pkgs.jq
      config.nix.package
    ];
    text = ''
      repository=${lib.escapeShellArg cfg.repository}
      branch=${lib.escapeShellArg cfg.branch}
      flake=${lib.escapeShellArg cfg.flake}
      plan_attr=${lib.escapeShellArg cfg.planAttr}
      metrics_url=${lib.escapeShellArg cfg.metricsUrl}
      soak_seconds=${toString (cfg.soakHours * 3600)}
      state_dir=${stateDirectory}
      mirror="$state_dir/mirror.git"
      now="$(date +%s)"
      today="$(date -u +%F)"

      mkdir -p "$state_dir/public" "$state_dir/roots"

      write_atomic() {
        local target=$1
        local staged
        staged="$(mktemp "$target.XXXXXX")"
        cat > "$staged"
        chmod 0644 "$staged"
        mv -f "$staged" "$target"
      }

      read_json() {
        local value
        value="$(cat "$1" 2>/dev/null || true)"
        if jq -e 'type == "object"' <<< "$value" > /dev/null 2>&1; then
          printf '%s' "$value"
        else
          printf '{}'
        fi
      }

      revision_url() {
        printf '%s?rev=%s' "$flake" "$1"
      }

      query() {
        curl -fsS --get --connect-timeout 10 --max-time 60 \
          --data-urlencode "query=label_replace($1, \"node\", \"\$1\", \"instance\", \"([^.:]+).*\")" \
          "$metrics_url/api/v1/query" \
          | jq -ce 'select(.status == "success") | [.data.result[] | {node: .metric.node, revision: (.metric.revision // null), value: (.value[1] | tonumber)}]'
      }

      fetch_metrics() {
        local running failed upgrade_failed down
        running="$(query "max by (instance, revision) (fleet_nixos_system_info) * on(instance) group_left() max by (instance) (time() - fleet_nixos_system_activation_timestamp_seconds)")" || return 1
        failed="$(query "count by (instance) (node_systemd_unit_state{state=\"failed\"} == 1 or fleet_user_systemd_unit_failed == 1)")" || return 1
        upgrade_failed="$(query "max by (instance, revision) (fleet_upgrade_state{state=\"failed\"} == 1)")" || return 1
        down="$(query "max by (instance, revision) (last_over_time(fleet_nixos_system_info[''${soak_seconds}s])) and on(instance) (up{job=~\"fleet-node.*\",always_on=\"true\"} == 0)")" || return 1
        jq -nc --argjson running "$running" --argjson failed "$failed" --argjson upgrade_failed "$upgrade_failed" --argjson down "$down" \
          '{running: $running, failed: $failed, upgrade_failed: $upgrade_failed, down: $down}'
      }

      [[ -d $mirror ]] || git init --bare --quiet "$mirror"
      git -C "$mirror" fetch --quiet --prune "$repository" "+refs/heads/$branch:refs/heads/$branch"
      history="$(git -C "$mirror" rev-list --max-count=${toString historyLength} "refs/heads/$branch" | jq -Rsc 'split("\n") | map(select(test("^[0-9a-f]{40}$")))')"
      deploy_revision="$(jq -er '.[0]' <<< "$history")"

      inventory="$(nix eval --json "$(revision_url "$deploy_revision")#$plan_attr")"
      jq -e '.hosts | type == "object"' <<< "$inventory" > /dev/null

      metrics="$(fetch_metrics)" || metrics=null

      gated="$(jq -nc -f ${gate} \
        --argjson history "$history" \
        --argjson inventory "$inventory" \
        --argjson approved "$(read_json "$state_dir/approved.json")" \
        --argjson metrics "$metrics" \
        --argjson soak "$soak_seconds" \
        --argjson now "$now" \
        --arg today "$today")"
      jq '.approved' <<< "$gated" | write_atomic "$state_dir/approved.json"

      old_builds="$(read_json "$state_dir/builds.json")"
      builds='{}'
      while IFS=$'\t' read -r target_host revision cache; do
        key="$revision/$target_host"
        previous="$(jq -c --arg key "$key" '.[$key] // null' <<< "$old_builds")"
        if [[ "$(jq -r --argjson now "$now" '.toplevel != null or (.error != null and $now - .at < 3600)' <<< "$previous")" == true ]]; then
          builds="$(jq -c --arg key "$key" --argjson build "$previous" '.[$key] = $build' <<< "$builds")"
          continue
        fi
        attribute="$(revision_url "$revision")#nixosConfigurations.\"$target_host\".config.system.build.toplevel"
        if [[ $cache == true ]]; then
          echo "fleet-deploy: building $target_host at $revision"
          toplevel="$(nix build --out-link "$state_dir/roots/$target_host" --print-out-paths "$attribute")" || toplevel=
        else
          echo "fleet-deploy: evaluating $target_host at $revision"
          toplevel="$(nix eval --raw "$attribute.outPath")" || toplevel=
        fi
        if [[ -n $toplevel ]]; then
          build="$(jq -nc --arg toplevel "$toplevel" --argjson now "$now" '{toplevel: $toplevel, at: $now}')"
        else
          echo "fleet-deploy: $target_host at $revision failed" >&2
          build="$(jq -nc --argjson now "$now" '{toplevel: null, error: "build failed", at: $now}')"
        fi
        builds="$(jq -c --arg key "$key" --argjson build "$build" '.[$key] = $build' <<< "$builds")"
      done < <(jq -r '.hosts | to_entries[] | select(.value.revision != null) | [.key, .value.revision, .value.cache] | @tsv' <<< "$gated")
      write_atomic "$state_dir/builds.json" <<< "$builds"

      jq -n \
        --argjson gated "$gated" \
        --argjson builds "$builds" \
        --argjson history "$history" \
        --argjson now "$now" '
        {
          generated_at: $now,
          deploy_revision: $history[0],
          history: $history,
          waves: ($gated.gates | with_entries(.value += {approved: ($gated.approved[.key].revision // null)})),
          hosts: ($gated.hosts | with_entries(
            .key as $host
            | (if .value.revision == null then null else $builds["\(.value.revision)/\($host)"] end) as $build
            | .value |= (
                if .state != "ready" then . + {toplevel: null}
                elif $build.toplevel != null then . + {state: "planned", toplevel: $build.toplevel}
                elif $build.error != null then . + {state: "build-failed", reason: "build", toplevel: null}
                else . + {state: "waiting", reason: "build", toplevel: null}
                end
              )
              | .value |= del(.cache)
          ))
        }
      ' | write_atomic "$state_dir/public/plan.json"

      jq -r '
        "# HELP fleet_deploy_revision_info Current commit on the deploy branch.",
        "# TYPE fleet_deploy_revision_info gauge",
        "fleet_deploy_revision_info{revision=\"\(.deploy_revision)\"} 1",
        "# HELP fleet_deploy_wave_info Revision approved for each rollout wave and the state of its gate.",
        "# TYPE fleet_deploy_wave_info gauge",
        (.waves | to_entries[] | "fleet_deploy_wave_info{wave=\"\(.key)\",revision=\"\(.value.approved // "")\",candidate=\"\(.value.candidate // "")\",state=\"\(.value.state)\"} 1"),
        "# HELP fleet_deploy_host_info Planned generation of each deployable host.",
        "# TYPE fleet_deploy_host_info gauge",
        (.hosts | to_entries[] | "fleet_deploy_host_info{host=\"\(.key)\",wave=\"\(.value.wave)\",revision=\"\(.value.revision // "")\",state=\"\(.value.state)\",reason=\"\(.value.reason)\"} 1"),
        "# HELP fleet_deploy_last_success_timestamp_seconds Time of the latest complete controller run.",
        "# TYPE fleet_deploy_last_success_timestamp_seconds gauge",
        "fleet_deploy_last_success_timestamp_seconds \(.generated_at)"
      ' "$state_dir/public/plan.json" | write_atomic "$state_dir/fleet-deploy.prom"
    '';
  };

  publishMetrics = pkgs.writeShellScript "publish-fleet-deploy-metrics" ''
    if [[ -s ${stateDirectory}/fleet-deploy.prom ]]; then
      ${pkgs.coreutils}/bin/install -D -m 0644 ${stateDirectory}/fleet-deploy.prom ${metricsDirectory}/fleet-deploy.prom
    fi
  '';
in
{
  options.services.fleet-deploy-controller = {
    repository = lib.mkOption {
      type = lib.types.str;
      example = "https://github.com/example/fleet.git";
      description = "Git repository that holds the deploy branch. Its history orders the revisions.";
    };
    branch = lib.mkOption {
      type = lib.types.str;
      default = "deploy";
      description = "Branch that holds only revisions that passed CI.";
    };
    flake = lib.mkOption {
      type = lib.types.strMatching "[^?]+";
      example = "github:example/fleet";
      description = "Flake reference of the repository without a revision. Hosts build the same reference.";
    };
    planAttr = lib.mkOption {
      type = lib.types.str;
      default = "lib.intent.deployPlan";
      description = "Flake attribute with the deploy plan inputs of the inventory.";
    };
    metricsUrl = lib.mkOption {
      type = lib.types.str;
      example = "http://metrics.example:8428";
      description = "Prometheus-compatible query API that holds the fleet metrics.";
    };
    soakHours = lib.mkOption {
      type = lib.types.ints.positive;
      default = 6;
      description = "Time the trusted hosts of a wave must run a revision without failures before the next wave takes it.";
    };
    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 5102;
    };
  };

  config = {
    assertions = [
      {
        assertion = host.deploy.controller;
        message = "host '${host.id}' runs the fleet deploy controller but does not set deploy.controller = true.";
      }
    ];

    users = {
      groups.fleet-deploy = { };
      users.fleet-deploy = {
        isSystemUser = true;
        group = "fleet-deploy";
        home = stateDirectory;
      };
    };

    nix = {
      daemonCPUSchedPolicy = lib.mkDefault "idle";
      daemonIOSchedClass = lib.mkDefault "idle";
    };

    systemd = {
      services.fleet-deploy-controller = {
        description = "Gate, build and publish the fleet deployment plan";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        restartIfChanged = false;
        environment = {
          HOME = stateDirectory;
          SSL_CERT_FILE = config.security.pki.caBundle;
        };
        serviceConfig = {
          Type = "oneshot";
          User = "fleet-deploy";
          Group = "fleet-deploy";
          StateDirectory = "fleet-deploy";
          StateDirectoryMode = "0755";
          ExecStart = lib.getExe controller;
          ExecStopPost = "+${publishMetrics}";
          TimeoutStartSec = "6h";
        };
      };

      timers.fleet-deploy-controller = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5m";
          OnUnitInactiveSec = "10m";
        };
      };

      tmpfiles.rules = [
        "d ${stateDirectory} 0755 fleet-deploy fleet-deploy -"
        "d ${stateDirectory}/public 0755 fleet-deploy fleet-deploy -"
      ];
    };

    services.static-web-server = {
      enable = true;
      listen = "[::]:${toString cfg.listenPort}";
      root = "${stateDirectory}/public";
    };

    environment.persistence = lib.mkIf impermanenceEnabled {
      "/persist/system".directories = [
        {
          directory = stateDirectory;
          user = "fleet-deploy";
          group = "fleet-deploy";
          mode = "0755";
        }
      ];
    };

    networking.firewall.interfaces.${tailnetInterface}.allowedTCPPorts = [ cfg.listenPort ];
  };
}
