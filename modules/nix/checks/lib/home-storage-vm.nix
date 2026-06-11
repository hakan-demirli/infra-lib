{
  pkgs,
  self,
}:
let
  mkPolicy =
    name: temporaryDefault: layout:
    pkgs.runCommand "home-storage-${name}-generation" { } ''
      mkdir -p "$out"
      cat > "$out/layout.conf" <<'EOF'
      ${layout}
      EOF
      ${pkgs.lib.optionalString temporaryDefault ''
        touch "$out/temporary-default"
      ''}
    '';

  fixtureFile = pkgs.writeText "home-storage-replay-fixture" "fixture\n";
  aliceBootReplay = pkgs.writeShellScript "home-storage-alice-boot-replay" ''
    set -euo pipefail
    touch "$HOME/.boot-replayed"
  '';
  aliceHomeFiles = pkgs.runCommand "home-storage-alice-home-manager-files" { } ''
    mkdir -p "$out/.config/systemd/user"
    ln -s ${fixtureFile} "$out/.bashrc"
    ln -s ${fixtureFile} "$out/.config/systemd/user/fixture.service"
  '';
  aliceHomePath = pkgs.runCommand "home-storage-alice-home-manager-path" { } ''
    mkdir -p "$out/bin"
  '';
  aliceGeneration = pkgs.runCommand "home-storage-alice-home-manager-generation" { } ''
    mkdir -p "$out/home-storage-policy"
    ln -s ${aliceHomeFiles} "$out/home-files"
    ln -s ${aliceHomePath} "$out/home-path"
    ln -s ${aliceBootReplay} "$out/boot-replay"
    cat > "$out/home-storage-policy/layout.conf" <<'EOF'
    d "/home/alice/.storage/persistent/Desktop" 0700 - - - -
    L "/home/alice/Desktop" - - - - /home/alice/.storage/persistent/Desktop
    EOF
    touch "$out/home-storage-policy/temporary-default"
  '';
  aliceGenerationId = builtins.unsafeDiscardStringContext (builtins.baseNameOf aliceGeneration);
  bobGeneration = mkPolicy "bob" false ''
    d "/home/bob/.storage/temporary/.cache" 0700 - - - -
    L "/home/bob/.cache" - - - - /home/bob/.storage/temporary/.cache
    d "/home/bob/.storage/temporary/Existing" 0700 - - - -
    L "/home/bob/Existing" - - - - /home/bob/.storage/temporary/Existing
  '';
  carolGeneration = mkPolicy "carol" true ''
    d "/home/carol/.storage/persistent/.cache" 0700 - - - -
    L "/home/carol/.cache" - - - - /home/carol/.storage/persistent/.cache
  '';

  host = {
    id = "home-storage-vm";
    impermanence = {
      enable = true;
      rollback_backend = "btrfs";
      home_mode = "user-managed";
      persisted_paths = [ ];
      persisted_files = [ ];
    };
  };

  users = {
    mike = 1000;
    alice = 1001;
    bob = 1002;
    carol = 1003;
  };
  cluster = {
    users = pkgs.lib.mapAttrs (_: uid: {
      archived = false;
      system_account = { inherit uid; };
    }) users;
    usersOnHost.home-storage-vm = map (user: { inherit user; }) (pkgs.lib.attrNames users);
  };
  clusterWithUsernames = cluster // {
    users = pkgs.lib.mapAttrs (
      username: value:
      value
      // {
        system_account = value.system_account // {
          inherit username;
        };
      }
    ) cluster.users;
  };
in
pkgs.testers.runNixOSTest {
  name = "home-storage-vm";

  nodes.machine = {
    imports = [ (self + "/modules/system/home-storage") ];

    _module.args = {
      inherit host;
      cluster = clusterWithUsernames;
    };

    fileSystems."/persist" = {
      device = "none";
      fsType = "tmpfs";
      neededForBoot = true;
    };

    users.users = pkgs.lib.mapAttrs (username: uid: {
      isNormalUser = true;
      inherit uid;
      home = "/home/${username}";
    }) users;

    systemd.tmpfiles.settings."20-home-storage-test" = {
      "/persist/home/alice/control/generations".d = {
        user = "alice";
        group = "users";
        mode = "0700";
      };
      "/persist/home/alice/control/generations/${aliceGenerationId}".L = {
        user = "alice";
        group = "users";
        argument = toString aliceGeneration;
      };
      "/persist/home/alice/control/current".L = {
        user = "alice";
        group = "users";
        argument = "generations/${aliceGenerationId}/home-storage-policy";
      };
      "/persist/home/bob/control/generations".d = {
        user = "bob";
        group = "users";
        mode = "0700";
      };
      "/persist/home/bob/control/generations/legacy".L = {
        user = "bob";
        group = "users";
        argument = toString bobGeneration;
      };
      "/persist/home/bob/control/current".L = {
        user = "bob";
        group = "users";
        argument = "generations/legacy";
      };
      "/persist/home/carol/control/generations".d = {
        user = "carol";
        group = "users";
        mode = "0700";
      };
      "/persist/home/carol/control/generations/legacy".L = {
        user = "carol";
        group = "users";
        argument = toString carolGeneration;
      };
      "/persist/home/carol/control/current".L = {
        user = "carol";
        group = "users";
        argument = "generations/legacy";
      };
      "/persist/home/bob/root/Existing".d = {
        user = "bob";
        group = "users";
        mode = "0700";
      };
      "/persist/home/bob/root/Existing/unmanaged".f = {
        user = "bob";
        group = "users";
        mode = "0600";
      };
    };

    system.stateVersion = "26.05";
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("home-storage-prepare.service")
    machine.succeed("systemctl start user@1001.service user@1002.service user@1003.service")
    machine.succeed("systemctl is-active user@1001.service user@1002.service user@1003.service")

    machine.succeed("test \"$(stat -c %d:%i /home/mike)\" = \"$(stat -c %d:%i /persist/home/mike/root)\"")
    machine.succeed("findmnt --mountpoint /home/mike/.storage/control")

    machine.succeed("test \"$(stat -c %d:%i /home/alice)\" = \"$(stat -c %d:%i /volatile/home/alice/root)\"")
    machine.succeed("test \"$(readlink /home/alice/Desktop)\" = /home/alice/.storage/persistent/Desktop")
    machine.succeed("test \"$(readlink -e /home/alice/.bashrc)\" = ${fixtureFile}")
    machine.succeed("test -L /home/alice/.config/systemd/user/fixture.service")
    machine.succeed("test -e /home/alice/.boot-replayed")
    machine.succeed("test \"$(readlink /home/alice/.local/state/nix/profiles/profile)\" = profile-1-link")
    machine.succeed("test \"$(readlink -e /home/alice/.nix-profile)\" = \"$(readlink -e ${aliceGeneration}/home-path)\"")

    machine.succeed("test \"$(stat -c %d:%i /home/bob)\" = \"$(stat -c %d:%i /persist/home/bob/root)\"")
    machine.succeed("test \"$(readlink /home/bob/.cache)\" = /home/bob/.storage/temporary/.cache")

    machine.succeed("test \"$(stat -c %d:%i /home/carol)\" = \"$(stat -c %d:%i /volatile/home/carol/root)\"")
    machine.succeed("test \"$(readlink /home/carol/.cache)\" = /home/carol/.storage/persistent/.cache")

    machine.succeed("test -f /home/bob/Existing/unmanaged")
    machine.fail("test -L /home/bob/Existing")

    machine.fail("runuser -u alice -- touch /home/bob/cross-user")
    machine.fail("runuser -u alice -- touch /persist/home/bob/control/current/temporary-default")
    machine.fail("runuser -u alice -- test -r /persist/home/bob/control/current/layout.conf")
    machine.fail("runuser -u alice -- rm -rf /persist/home/bob/paths")
    machine.succeed("test -d /persist/home/bob/paths")

    machine.succeed("systemctl stop user@1001.service home-storage-user@1001.service")
    machine.succeed("runuser -u alice -- mkdir /persist/home/alice/control/security-test")
    machine.succeed("runuser -u alice -- sh -c 'printf \"f /home/bob/cross-user-layout 0600 - - - -\\n\" > /persist/home/alice/control/security-test/layout.conf'")
    machine.succeed("runuser -u alice -- ln -sfn security-test /persist/home/alice/control/current")
    machine.fail("systemctl restart home-storage-layout-alice.service")
    machine.fail("test -e /home/bob/cross-user-layout")
    machine.succeed("systemctl is-active systemd-user-sessions.service")
    machine.succeed("systemctl is-active user@1002.service")
    machine.fail("systemctl start user@1001.service")
    machine.fail("systemctl is-active user@1001.service")
    machine.succeed("runuser -u alice -- ln -sfn generations/${aliceGenerationId}/home-storage-policy /persist/home/alice/control/current")
    machine.succeed("systemctl restart home-storage-layout-alice.service")
    machine.succeed("test \"$(stat -c %d:%i /home/bob)\" = \"$(stat -c %d:%i /persist/home/bob/root)\"")

    machine.succeed("runuser -u alice -- touch /home/alice/temporary-data")
    machine.succeed("runuser -u alice -- touch /home/alice/Desktop/persistent-data")
    machine.succeed("runuser -u bob -- touch /home/bob/persistent-data")
    machine.succeed("runuser -u bob -- touch /home/bob/.cache/temporary-data")
    machine.succeed("runuser -u carol -- touch /home/carol/temporary-data")
    machine.succeed("runuser -u carol -- touch /home/carol/.cache/persistent-data")

    machine.succeed("systemctl stop user@1001.service user@1002.service user@1003.service")
    machine.succeed("systemctl stop home-storage-user@1001.service home-storage-user@1002.service home-storage-user@1003.service")
    machine.succeed("systemctl stop home-storage-prepare.service")
    machine.succeed("systemctl stop home-generation-replay-mike.service home-generation-replay-alice.service home-generation-replay-bob.service home-generation-replay-carol.service")
    machine.succeed("systemctl stop home-storage-layout-alice.service home-storage-layout-bob.service home-storage-layout-carol.service")
    machine.succeed("systemctl stop home-storage-buckets-mike.service home-storage-buckets-alice.service home-storage-buckets-bob.service home-storage-buckets-carol.service")
    machine.succeed("systemctl stop home-storage-root-persistent-mike.service home-storage-root-temporary-alice.service home-storage-root-persistent-bob.service home-storage-root-temporary-carol.service")
    machine.succeed("rm -rf /volatile/home")
    machine.succeed("systemd-tmpfiles --create --prefix=/volatile/home")
    machine.succeed("systemctl restart home-storage-prepare.service")
    machine.succeed("systemctl start user@1001.service user@1002.service user@1003.service")

    machine.fail("test -e /home/alice/temporary-data")
    machine.succeed("test -e /home/alice/Desktop/persistent-data")
    machine.succeed("test \"$(readlink -e /home/alice/.bashrc)\" = ${fixtureFile}")
    machine.succeed("test -e /home/alice/.boot-replayed")
    machine.succeed("test -e /home/bob/persistent-data")
    machine.fail("test -e /home/bob/.cache/temporary-data")
    machine.fail("test -e /home/carol/temporary-data")
    machine.succeed("test -e /home/carol/.cache/persistent-data")
  '';
}
