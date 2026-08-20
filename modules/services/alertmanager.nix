{
  config,
  lib,
  pkgs,
  host ? null,
  ...
}:
let
  cfg = config.services.cluster-alertmanager;
  inherit (cfg) channels;
  impermanenceEnabled = host != null && (host.impermanence.enable or false);

  notificationTemplate = pkgs.writeText "cluster-alertmanager.tmpl" ''
    {{ define "cluster.title" -}}
    [{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}] {{ .GroupLabels.alertname }}{{ with .CommonLabels.severity }} ({{ . }}){{ end }}
    {{- end }}

    {{ define "cluster.message" -}}
    {{ range .Alerts.Firing -}}
    FIRING: {{ or .Annotations.summary .Labels.alertname }}
    {{ with .Annotations.description }}{{ . }}
    {{ end -}}
    {{ with .Labels.instance }}Instance: {{ . }}
    {{ end -}}
    {{ with .GeneratorURL }}Source: {{ . }}
    {{ end -}}
    {{ end -}}
    {{ range .Alerts.Resolved -}}
    RESOLVED: {{ or .Annotations.summary .Labels.alertname }}
    {{ with .Annotations.description }}{{ . }}
    {{ end -}}
    {{ with .Labels.instance }}Instance: {{ . }}
    {{ end -}}
    {{ with .GeneratorURL }}Source: {{ . }}
    {{ end -}}
    {{ end -}}
    {{- end }}
  '';

  sendAlert = pkgs.writeShellApplication {
    name = "send-alert";
    runtimeInputs = [ config.services.prometheus.alertmanager.package ];
    text = ''
      usage() {
        cat <<'EOF'
      usage: send-alert ALERT_NAME severity=critical|warning [label=value ...]
                        [--annotation=NAME=VALUE ...] [--generator-url=URL]
                        [--start=RFC3339] [--end=RFC3339]

      Examples:
        send-alert BackupFailed severity=critical host=server-0 \
          --annotation=summary='Backup failed' \
          --annotation=description='The nightly backup exited unsuccessfully.'
        send-alert DeployDegraded severity=warning --annotation=summary='Deployment degraded'
      EOF
      }

      if [[ $# -eq 0 ]]; then
        usage >&2
        exit 2
      fi

      die() {
        echo "send-alert: $*" >&2
        exit 2
      }

      alert_name=""
      severity=""
      generator_url=""
      starts_at=""
      ends_at=""
      labels=()
      annotations=()

      while [[ $# -gt 0 ]]; do
        arg=$1
        shift
        case "$arg" in
          -h | --help)
            usage
            exit 0
            ;;
          --annotation | --generator-url | --start | --end)
            [[ $# -gt 0 ]] || die "$arg requires a value"
            value=$1
            shift
            [[ -n $value ]] || die "$arg requires a non-empty value"
            case "$arg" in
              --annotation) annotations+=("$value") ;;
              --generator-url) generator_url=$value ;;
              --start) starts_at=$value ;;
              --end) ends_at=$value ;;
            esac
            ;;
          --annotation=*)
            value=''${arg#--annotation=}
            [[ -n $value ]] || die "--annotation requires a non-empty value"
            annotations+=("$value")
            ;;
          --generator-url=*)
            generator_url=''${arg#--generator-url=}
            [[ -n $generator_url ]] || die "--generator-url requires a non-empty value"
            ;;
          --start=*)
            starts_at=''${arg#--start=}
            [[ -n $starts_at ]] || die "--start requires a non-empty value"
            ;;
          --end=*)
            ends_at=''${arg#--end=}
            [[ -n $ends_at ]] || die "--end requires a non-empty value"
            ;;
          severity=*)
            [[ -z $severity ]] || die "severity may only be specified once"
            severity=''${arg#severity=}
            case "$severity" in
              critical | warning) ;;
              *) die "severity must be critical or warning" ;;
            esac
            ;;
          alertname=*)
            [[ -z $alert_name ]] || die "alert name may only be specified once"
            alert_name=''${arg#alertname=}
            [[ -n $alert_name ]] || die "alert name must not be empty"
            ;;
          -* )
            die "unsupported option: $arg"
            ;;
          *=*)
            labels+=("$arg")
            ;;
          *)
            [[ -z $alert_name ]] || die "unexpected positional argument: $arg"
            [[ -n $arg ]] || die "alert name must not be empty"
            alert_name=$arg
            ;;
        esac
      done

      if [[ -z $alert_name ]]; then
        die "an alert name is required"
      fi
      if [[ ! $alert_name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        die "alert name must match [A-Za-z_][A-Za-z0-9_]*"
      fi

      if [[ -z $severity ]]; then
        echo "send-alert: a severity=critical or severity=warning label is required" >&2
        exit 2
      fi

      amtool_args=("alertname=$alert_name" "severity=$severity" "''${labels[@]}")
      for annotation in "''${annotations[@]}"; do
        amtool_args+=("--annotation=$annotation")
      done
      if [[ -n $generator_url ]]; then
        amtool_args+=("--generator-url=$generator_url")
      fi
      if [[ -n $starts_at ]]; then
        amtool_args+=("--start=$starts_at")
      fi
      if [[ -n $ends_at ]]; then
        amtool_args+=("--end=$ends_at")
      fi

      exec amtool \
        --alertmanager.url=${lib.escapeShellArg "http://127.0.0.1:${toString cfg.listenPort}"} \
        alert add "''${amtool_args[@]}"
    '';
  };

  webhookConfigs =
    lib.optional channels.ntfy.enable {
      url = "http://127.0.0.1:${toString channels.ntfy.adapterPort}/hook";
      send_resolved = cfg.sendResolved;
    }
    ++ lib.optional (cfg.webhookUrl != null) {
      url = cfg.webhookUrl;
      send_resolved = cfg.sendResolved;
    };

  telegramConfigs = lib.optional channels.telegram.enable (
    {
      api_url = channels.telegram.apiUrl;
      bot_token_file = channels.telegram.botTokenFile;
      chat_id_file = channels.telegram.chatIdFile;
      disable_notifications = channels.telegram.disableNotifications;
      message = ''{{ template "cluster.message" . }}'';
      parse_mode = "";
      send_resolved = cfg.sendResolved;
    }
    // lib.optionalAttrs (channels.telegram.messageThreadId != null) {
      message_thread_id = channels.telegram.messageThreadId;
    }
  );

  discordConfigs = lib.optional channels.discord.enable {
    webhook_url_file = channels.discord.webhookUrlFile;
    username = channels.discord.username;
    title = ''{{ template "cluster.title" . }}'';
    message = ''{{ template "cluster.message" . }}'';
    send_resolved = cfg.sendResolved;
  };

  emailConfigs = lib.optional channels.email.enable (
    {
      to = channels.email.to;
      from = channels.email.from;
      smarthost = channels.email.smarthost;
      headers.Subject = ''{{ template "cluster.title" . }}'';
      html = "";
      text = ''{{ template "cluster.message" . }}'';
      require_tls = channels.email.requireTLS;
      send_resolved = cfg.sendResolved;
    }
    // lib.optionalAttrs (channels.email.hello != null) {
      hello = channels.email.hello;
    }
    // lib.optionalAttrs (channels.email.authUsername != null) {
      auth_username = channels.email.authUsername;
      auth_password_file = channels.email.authPasswordFile;
    }
    // lib.optionalAttrs (channels.email.forceImplicitTLS != null) {
      force_implicit_tls = channels.email.forceImplicitTLS;
    }
  );

  fanoutReceiver = {
    name = "fanout";
  }
  // lib.optionalAttrs (webhookConfigs != [ ]) {
    webhook_configs = webhookConfigs;
  }
  // lib.optionalAttrs (telegramConfigs != [ ]) {
    telegram_configs = telegramConfigs;
  }
  // lib.optionalAttrs (discordConfigs != [ ]) {
    discord_configs = discordConfigs;
  }
  // lib.optionalAttrs (emailConfigs != [ ]) {
    email_configs = emailConfigs;
  };
in
{
  options.services.cluster-alertmanager = {
    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 9093;
    };
    webhookUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional additional webhook receiver URL for actionable alerts.";
    };
    groupWait = lib.mkOption {
      type = lib.types.str;
      default = "10s";
    };
    groupInterval = lib.mkOption {
      type = lib.types.str;
      default = "5m";
    };
    repeatInterval = lib.mkOption {
      type = lib.types.str;
      default = "4h";
    };
    sendResolved = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

    channels = {
      ntfy = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Send formatted actionable alerts through ntfy.";
        };
        baseUrl = lib.mkOption {
          type = lib.types.str;
          default = "http://127.0.0.1:8111";
          description = "Base URL of the ntfy server.";
        };
        topic = lib.mkOption {
          type = lib.types.strMatching "[-_A-Za-z0-9]{1,64}";
          default = "alerts";
        };
        adapterPort = lib.mkOption {
          type = lib.types.port;
          default = 8000;
        };
        extraConfigFiles = lib.mkOption {
          type = lib.types.listOf lib.types.path;
          default = [ ];
          description = "Runtime configuration files merged into alertmanager-ntfy, typically for ntfy authentication.";
        };
      };

      telegram = {
        enable = lib.mkEnableOption "Telegram alert delivery";
        apiUrl = lib.mkOption {
          type = lib.types.str;
          default = "https://api.telegram.org";
        };
        botTokenFile = lib.mkOption {
          type = lib.types.str;
          default = "/run/secrets/alertmanager-telegram-bot-token";
          description = "Runtime file containing the Telegram bot token.";
        };
        chatIdFile = lib.mkOption {
          type = lib.types.str;
          default = "/run/secrets/alertmanager-telegram-chat-id";
          description = "Runtime file containing the Telegram chat ID.";
        };
        messageThreadId = lib.mkOption {
          type = lib.types.nullOr lib.types.ints.unsigned;
          default = null;
        };
        disableNotifications = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
      };

      discord = {
        enable = lib.mkEnableOption "Discord alert delivery";
        webhookUrlFile = lib.mkOption {
          type = lib.types.str;
          default = "/run/secrets/alertmanager-discord-webhook-url";
          description = "Runtime file containing the Discord webhook URL.";
        };
        username = lib.mkOption {
          type = lib.types.str;
          default = "Alertmanager";
        };
      };

      email = {
        enable = lib.mkEnableOption "email alert delivery";
        smarthost = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "smtp.example.com:587";
        };
        from = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        to = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        hello = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        authUsername = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        authPasswordFile = lib.mkOption {
          type = lib.types.str;
          default = "/run/secrets/alertmanager-smtp-password";
          description = "Runtime file containing the SMTP password when authUsername is configured.";
        };
        requireTLS = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        forceImplicitTLS = lib.mkOption {
          type = lib.types.nullOr lib.types.bool;
          default = null;
        };
      };
    };
  };

  config = {
    assertions = [
      {
        assertion =
          !channels.email.enable
          || (channels.email.smarthost != null && channels.email.from != null && channels.email.to != null);
        message = "services.cluster-alertmanager.channels.email requires smarthost, from, and to.";
      }
    ];

    services.prometheus = {
      alertmanager = {
        enable = true;
        port = cfg.listenPort;
        openFirewall = true;
        configuration = {
          global = { };
          templates = [ notificationTemplate ];
          route = {
            receiver = "drop";
            group_by = [ "alertname" ];
            group_wait = cfg.groupWait;
            group_interval = cfg.groupInterval;
            repeat_interval = cfg.repeatInterval;
            routes = [
              {
                receiver = "fanout";
                matchers = [ ''severity=~"critical|warning"'' ];
              }
            ];
          };
          receivers = [
            { name = "drop"; }
            fanoutReceiver
          ];
        };
      };

      alertmanager-ntfy = lib.mkIf channels.ntfy.enable {
        enable = true;
        settings = {
          http.addr = "127.0.0.1:${toString channels.ntfy.adapterPort}";
          ntfy = {
            baseurl = channels.ntfy.baseUrl;
            async = false;
            notification = {
              topic = channels.ntfy.topic;
              priority = ''
                status == "resolved" ? "default" : labels["severity"] == "critical" ? "urgent" : "high"
              '';
              tags = [
                {
                  tag = "heavy_check_mark";
                  condition = ''status == "resolved"'';
                }
                {
                  tag = "rotating_light";
                  condition = ''status == "firing" && labels["severity"] == "critical"'';
                }
                {
                  tag = "warning";
                  condition = ''status == "firing" && labels["severity"] == "warning"'';
                }
              ];
              templates = {
                title = ''
                  {{ if eq .Status "resolved" }}[RESOLVED]{{ else }}[FIRING]{{ end }} {{ or (index .Annotations "summary") (index .Labels "alertname") }}
                '';
                description = ''
                  {{ with index .Annotations "description" }}{{ . }}{{ else }}Alert {{ index .Labels "alertname" }} changed state.{{ end }}
                  {{ with index .Labels "instance" }}
                  Instance: {{ . }}{{ end }}
                '';
                headers.X-Click = "{{ .GeneratorURL }}";
              };
            };
          };
        };
        extraConfigFiles = channels.ntfy.extraConfigFiles;
      };
    };

    users.users.alertmanager = {
      isSystemUser = true;
      group = "alertmanager";
    };
    users.groups.alertmanager = { };

    environment.systemPackages = [ sendAlert ];

    systemd.services.alertmanager = {
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "alertmanager";
        Group = "alertmanager";
      };
    }
    // lib.optionalAttrs channels.ntfy.enable {
      wants = [ "alertmanager-ntfy.service" ];
      after = [ "alertmanager-ntfy.service" ];
    };

    environment.persistence = lib.mkIf impermanenceEnabled {
      "/persist/system".directories = [
        {
          directory = "/var/lib/alertmanager";
          user = "alertmanager";
          group = "alertmanager";
          mode = "0700";
        }
      ];
    };
  };
}
