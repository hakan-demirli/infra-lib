{
  config,
  lib,
  pkgs,
  host ? null,
  ...
}:
let
  cfg = config.services.cluster-gitea;
  gitea = config.services.gitea;
  impermanenceEnabled = host != null && (host.impermanence.enable or false);

  useSops = cfg.admin.password.source == "sops";
  sopsKeyName =
    if cfg.admin.password.sopsKeyName == null then
      "__MISSING_SOPS_KEY__"
    else
      cfg.admin.password.sopsKeyName;
  passwordPath =
    if useSops then
      config.sops.secrets.${sopsKeyName}.path
    else if cfg.admin.password.hostLocalPath == null then
      "/dev/null"
    else
      cfg.admin.password.hostLocalPath;

  provisionAdmin = pkgs.writeShellApplication {
    name = "gitea-provision-admin";
    runtimeInputs = [
      pkgs.gawk
      gitea.package
    ];
    text = ''
      username=${lib.escapeShellArg cfg.admin.username}
      password_file="$CREDENTIALS_DIRECTORY/admin-password"

      if [[ ! -s "$password_file" ]]; then
        echo "fatal: the Gitea administrator password is missing or empty" >&2
        exit 1
      fi

      password="$(<"$password_file")"

      if gitea admin user list | awk -v user="$username" 'NR > 1 && $2 == user { found = 1 } END { exit !found }'; then
        gitea admin user change-password \
          --username "$username" \
          --password "$password" \
          --must-change-password=false
      else
        gitea admin user create \
          --admin \
          --username "$username" \
          --email ${lib.escapeShellArg cfg.admin.email} \
          --password "$password" \
          --must-change-password=false
      fi
    '';
  };
in
{
  options.services.cluster-gitea = {
    domain = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host name this forge is reached by. It is the authority in every
        generated HTTP and SSH clone URL, so it must be a name the clients
        actually resolve, typically the node's MagicDNS name.
      '';
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 3001;
    };

    sshPort = lib.mkOption {
      type = lib.types.port;
      default = 22;
      description = ''
        Port advertised in SSH clone URLs. Gitea does not run its own SSH
        daemon here; it publishes forced-command entries in the service
        user's authorized_keys and lets the host sshd dispatch them.
      '';
    };

    admin = {
      username = lib.mkOption {
        type = lib.types.str;
        description = "Login of the administrator provisioned on every activation.";
      };

      email = lib.mkOption {
        type = lib.types.str;
        description = "Address recorded for the provisioned administrator.";
      };

      password = {
        source = lib.mkOption {
          type = lib.types.enum [
            "sops"
            "host-local"
          ];
        };

        sopsKeyName = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };

        hostLocalPath = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
        };
      };
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion =
            !useSops || (cfg.admin.password.sopsKeyName != null && cfg.admin.password.hostLocalPath == null);
          message = "cluster-gitea admin.password.source=sops requires only admin.password.sopsKeyName.";
        }
        {
          assertion =
            useSops || (cfg.admin.password.hostLocalPath != null && cfg.admin.password.sopsKeyName == null);
          message = "cluster-gitea admin.password.source=host-local requires only admin.password.hostLocalPath.";
        }
      ];

      services.gitea = {
        enable = true;
        lfs.enable = true;
        database.type = "sqlite3";

        settings = {
          server = {
            HTTP_ADDR = "0.0.0.0";
            HTTP_PORT = cfg.listenPort;
            DOMAIN = cfg.domain;
            ROOT_URL = "http://${cfg.domain}:${toString cfg.listenPort}/";
            SSH_DOMAIN = cfg.domain;
            SSH_PORT = cfg.sshPort;
            START_SSH_SERVER = false;
            OFFLINE_MODE = true;
          };

          service = {
            DISABLE_REGISTRATION = true;
            REQUIRE_SIGNIN_VIEW = true;
          };

          actions.ENABLED = false;
          repository.DEFAULT_BRANCH = "main";
          "cron.update_checker".ENABLED = false;
        };
      };

      systemd.services.gitea-admin = {
        description = "Provision the declarative Gitea administrator";
        wantedBy = [ "multi-user.target" ];
        after = [ "gitea.service" ];
        requires = [ "gitea.service" ];

        environment = {
          USER = gitea.user;
          HOME = gitea.stateDir;
          GITEA_WORK_DIR = gitea.stateDir;
          GITEA_CUSTOM = gitea.customDir;
        };

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = gitea.user;
          Group = gitea.group;
          WorkingDirectory = gitea.stateDir;
          LoadCredential = [ "admin-password:${passwordPath}" ];
          ExecStart = lib.getExe provisionAdmin;
          UMask = "0027";
        };
      };

      environment.persistence = lib.mkIf impermanenceEnabled {
        "/persist/system".directories = [
          {
            directory = gitea.stateDir;
            inherit (gitea) user group;
            mode = "0750";
          }
        ];
      };
    }

    (lib.mkIf useSops {
      sops.secrets.${sopsKeyName} = { };

      systemd.services.gitea-admin = {
        after = [ "sops-install-secrets.service" ];
        requires = [ "sops-install-secrets.service" ];
      };
    })
  ];
}
