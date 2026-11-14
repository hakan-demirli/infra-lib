{
  config,
  lib,
  pkgs,
  host ? null,
  ...
}:
let
  cfg = config.services.cluster-forgejo;
  forgejo = config.services.forgejo;
  impermanenceEnabled = host != null && (host.impermanence.enable or false);

  # The project API of forgejo/forgejo#13714, which no Forgejo release has yet.
  # Its tests expect the Go 1.27 toolchain that the branch pins.
  package =
    pkgs.callPackage
      (import "${pkgs.path}/pkgs/by-name/fo/forgejo/generic.nix" {
        version = "18.0.0-dev-288-2d12edec";
        rev = "2d12edec93f56743a2ad5519be86e61d707aa11e";
        hash = "sha256-UyJyDSXM5y/3c/vxNzJFOCGPP99cTzBdx/8ivQFVLKQ=";
        npmDepsHash = "sha256-IjWhDYewobHG57taeJLKjhm/6/YKH5uiEse1nos3g3I=";
        vendorHash = "sha256-JU/6fW+FSwYINXVMpxPFym3lFYBzUlUSG3SVl3Hbzrw=";
      })
      {
        forgejo = package;
        buildGoModule = pkgs.buildGo127Module;
      };

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
    name = "forgejo-provision-admin";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.gawk
      pkgs.jq
      forgejo.package
    ];
    text = ''
      username=${lib.escapeShellArg cfg.admin.username}
      email=${lib.escapeShellArg cfg.admin.email}
      api=${lib.escapeShellArg "http://127.0.0.1:${toString cfg.listenPort}/api/v1"}
      password_file="$CREDENTIALS_DIRECTORY/admin-password"

      if [[ ! -s "$password_file" ]]; then
        echo "fatal: the Forgejo administrator password is missing or empty" >&2
        exit 1
      fi

      password="$(<"$password_file")"

      if forgejo admin user list | awk -v user="$username" 'NR > 1 && $2 == user { found = 1 } END { exit !found }'; then
        forgejo admin user change-password \
          --username "$username" \
          --password "$password" \
          --must-change-password=false
      else
        forgejo admin user create \
          --admin \
          --username "$username" \
          --email "$email" \
          --password "$password" \
          --must-change-password=false
      fi

      netrc="$RUNTIME_DIRECTORY/netrc"
      printf 'machine 127.0.0.1 login %s password %s\n' "$username" "$password" > "$netrc"

      for _ in $(seq 60); do
        curl -fsS -o /dev/null "$api/version" && break
        sleep 2
      done

      current="$(curl -fsS --netrc-file "$netrc" "$api/user" | jq -r .email)"
      if [[ $current != "$email" ]]; then
        echo "forgejo-provision-admin: changing the administrator address from $current to $email"
        jq -nc --arg email "$email" '{email: $email}' \
          | curl -fsS --netrc-file "$netrc" -X PATCH -H 'Content-Type: application/json' \
            --data @- -o /dev/null "$api/admin/users/$username"
      fi
    '';
  };
in
{
  options.services.cluster-forgejo = {
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
        Port advertised in SSH clone URLs. Forgejo does not run its own SSH
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
        description = "Primary address of the administrator, restored on every activation. Forgejo writes it into the commits it creates.";
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
          message = "cluster-forgejo admin.password.source=sops requires only admin.password.sopsKeyName.";
        }
        {
          assertion =
            useSops || (cfg.admin.password.hostLocalPath != null && cfg.admin.password.sopsKeyName == null);
          message = "cluster-forgejo admin.password.source=host-local requires only admin.password.hostLocalPath.";
        }
      ];

      services.forgejo = {
        enable = true;
        inherit package;
        lfs.enable = true;
        database.type = "sqlite3";

        # Forgejo 18 has no INTERNAL_TOKEN (forgejo/forgejo#14148); the nixpkgs module still declares it.
        secrets.security = lib.mkForce {
          SECRET_KEY = "${forgejo.customDir}/conf/secret_key";
        };

        settings = {
          server = {
            HTTP_ADDR = "0.0.0.0";
            HTTP_PORT = cfg.listenPort;
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

      systemd.services.forgejo-secrets = lib.mkForce {
        description = "Forgejo secret bootstrap helper";
        script = ''
          if [ ! -s '${forgejo.secrets.security.SECRET_KEY}' ]; then
            forgejo generate secret SECRET_KEY > '${forgejo.secrets.security.SECRET_KEY}'
          fi

          if [ ! -s '${forgejo.secrets.oauth2.JWT_SECRET}' ]; then
            forgejo generate secret JWT_SECRET > '${forgejo.secrets.oauth2.JWT_SECRET}'
          fi

          if [ ! -s '${forgejo.secrets.server.LFS_JWT_SECRET}' ]; then
            forgejo generate secret LFS_JWT_SECRET > '${forgejo.secrets.server.LFS_JWT_SECRET}'
          fi
        '';
        path = [ forgejo.package ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = forgejo.user;
          Group = forgejo.group;
          ReadWritePaths = [ forgejo.customDir ];
          UMask = "0077";
        };
      };

      systemd.services.forgejo-admin = {
        description = "Provision the declarative Forgejo administrator";
        wantedBy = [ "multi-user.target" ];
        after = [ "forgejo.service" ];
        requires = [ "forgejo.service" ];

        environment = {
          USER = forgejo.user;
          HOME = forgejo.stateDir;
          FORGEJO_WORK_DIR = forgejo.stateDir;
          FORGEJO_CUSTOM = forgejo.customDir;
        };

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = forgejo.user;
          Group = forgejo.group;
          WorkingDirectory = forgejo.stateDir;
          LoadCredential = [ "admin-password:${passwordPath}" ];
          RuntimeDirectory = "forgejo-admin";
          RuntimeDirectoryMode = "0700";
          ExecStart = lib.getExe provisionAdmin;
          UMask = "0027";
        };
      };

      environment.persistence = lib.mkIf impermanenceEnabled {
        "/persist/system".directories = [
          {
            directory = forgejo.stateDir;
            inherit (forgejo) user group;
            mode = "0750";
          }
        ];
      };
    }

    (lib.mkIf useSops {
      sops.secrets.${sopsKeyName} = { };

      systemd.services.forgejo-admin = {
        after = [ "sops-install-secrets.service" ];
        requires = [ "sops-install-secrets.service" ];
      };
    })
  ];
}
