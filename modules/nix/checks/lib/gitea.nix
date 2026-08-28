{ pkgs, inputs }:
let
  inherit (pkgs) lib;

  vmImpermanence = import ./lib/vm-impermanence.nix { inherit inputs; };

  adminUser = "forge-admin";
  adminPassword = "correct-horse-battery-staple";
  passwordFile = "/var/lib/gitea-test/admin-password";

  sopsOptionStubs = {
    options.sops.secrets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "gitea";

  nodes.forge = {
    imports = [
      vmImpermanence
      sopsOptionStubs
      ../../../services/gitea.nix
    ];

    _module.args.host = {
      id = "forge";
      impermanence.enable = true;
    };

    services.openssh.enable = true;

    services.cluster-gitea = {
      domain = "forge";
      admin = {
        username = adminUser;
        email = "${adminUser}@example.com";
        password = {
          source = "host-local";
          hostLocalPath = passwordFile;
        };
      };
    };

    systemd.services.gitea-test-password = {
      description = "Seed the Gitea administrator password for THIS TEST ONLY";
      wantedBy = [ "multi-user.target" ];
      before = [ "gitea-admin.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        install -d -m 0700 ${builtins.dirOf passwordFile}
        printf '%s' ${lib.escapeShellArg adminPassword} > ${passwordFile}
        chmod 0400 ${passwordFile}
      '';
    };

    environment.systemPackages = [
      pkgs.curl
      pkgs.git
      pkgs.jq
      pkgs.openssh
    ];

    virtualisation.memorySize = 2048;
  };

  testScript = ''
    import json
    import shlex

    api = "http://localhost:3001/api/v1"
    auth = "-u ${adminUser}:${adminPassword}"


    def api_get(path):
        return forge.succeed("curl -sf " + auth + " " + api + path)


    def api_post(path, payload):
        return forge.succeed(
            "curl -sf " + auth + " -X POST -H 'Content-Type: application/json' -d "
            + shlex.quote(json.dumps(payload))
            + " "
            + api
            + path
        )


    start_all()

    forge.wait_for_unit("gitea.service")
    forge.wait_for_open_port(3001)
    forge.wait_for_unit("gitea-admin.service")

    app_ini = "/var/lib/gitea/custom/conf/app.ini"
    forge.succeed("grep -q '^DISABLE_REGISTRATION *= *true' " + app_ini)
    forge.succeed("grep -q '^ROOT_URL *= *http://forge:3001/$' " + app_ini)

    anonymous = forge.succeed(
        "curl -s -o /dev/null -w '%{http_code}' " + api + "/user"
    ).strip()
    assert anonymous == "403", f"anonymous API access was not refused: {anonymous}"

    whoami = json.loads(api_get("/user"))
    assert whoami["login"] == "${adminUser}", whoami
    assert whoami["is_admin"] is True, whoami

    forge.succeed("mkdir -p /root/.ssh")
    forge.succeed("ssh-keygen -q -t ed25519 -N \"\" -f /root/.ssh/id_ed25519")
    pubkey = forge.succeed("cat /root/.ssh/id_ed25519.pub").strip()
    api_post("/user/keys", {"title": "test-key", "key": pubkey})

    repo = json.loads(api_post("/user/repos", {"name": "demo", "auto_init": True}))
    assert repo["ssh_url"] == "gitea@forge:${adminUser}/demo.git", repo["ssh_url"]

    forge.succeed(
        "GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null' "
        "git clone gitea@localhost:${adminUser}/demo.git /tmp/demo"
    )
    forge.succeed("test -f /tmp/demo/README.md")

    forge.succeed("systemctl restart gitea-admin.service")
    reprovisioned = json.loads(api_get("/user"))
    assert reprovisioned["login"] == "${adminUser}", reprovisioned

    print("GITEA VERIFICATIONS PASSED")
  '';
}
