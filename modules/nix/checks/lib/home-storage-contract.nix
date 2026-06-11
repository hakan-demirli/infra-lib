{
  pkgs,
  self,
  inputs,
}:
let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  host = {
    id = "home-storage-test";
    impermanence = {
      enable = true;
      rollback_backend = "btrfs";
      home_mode = "user-managed";
      persisted_paths = [ ];
      persisted_files = [ ];
    };
  };

  cluster = {
    users = {
      mike = {
        archived = false;
        system_account = {
          username = "mike";
          uid = 1000;
        };
      };
      anna = {
        archived = false;
        system_account = {
          username = "anna";
          uid = 1001;
        };
      };
    };
    usersOnHost.home-storage-test = [
      { user = "mike"; }
      { user = "anna"; }
    ];
  };

  fixtureFile = pkgs.writeText "home-replay-fixture" "fixture\n";
  foreignFile = pkgs.writeText "home-replay-foreign" "foreign\n";
  fixtureBootReplay = pkgs.writeShellScript "home-replay-fixture-boot" ''
    set -euo pipefail
    touch "$HOME/.boot-replayed"
    touch "$XDG_CONFIG_HOME/.boot-replayed"
  '';
  fixtureHomeFiles = pkgs.runCommand "fixture-home-manager-files" { } ''
    mkdir -p "$out/.config/systemd/user"
    ln -s ${fixtureFile} "$out/.bashrc"
    ln -s ${fixtureFile} "$out/.config/systemd/user/fixture.service"
  '';
  fixtureHomePath = pkgs.runCommand "fixture-home-manager-path" { } ''
    mkdir -p "$out/bin"
  '';
  fixtureGeneration = pkgs.runCommand "fixture-home-manager-generation" { } ''
    mkdir -p "$out/home-storage-policy"
    ln -s ${fixtureHomeFiles} "$out/home-files"
    ln -s ${fixtureHomePath} "$out/home-path"
    ln -s ${fixtureBootReplay} "$out/boot-replay"
    touch "$out/home-storage-policy/layout.conf"
  '';
  oldFixtureHomeFiles = pkgs.runCommand "fixture-old-home-manager-files" { } ''
    mkdir -p "$out"
    ln -s ${fixtureFile} "$out/.obsolete"
  '';
  oldFixtureGeneration = pkgs.runCommand "fixture-old-home-manager-generation" { } ''
    mkdir -p "$out"
    ln -s ${oldFixtureHomeFiles} "$out/home-files"
  '';

  evaluated = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = { inherit host cluster; };
    modules = [
      (self + "/modules/system/home-storage")
      {
        boot.isContainer = true;
        fileSystems."/persist" = {
          device = "none";
          fsType = "tmpfs";
          neededForBoot = true;
        };
        users.users = {
          mike = {
            isNormalUser = true;
            uid = 1000;
            home = "/home/mike";
          };
          anna = {
            isNormalUser = true;
            uid = 1001;
            home = "/home/anna";
          };
        };
        system.stateVersion = "26.05";
      }
    ];
  };

  services = evaluated.config.systemd.services;
  settings = evaluated.config.systemd.tmpfiles.settings."10-home-storage";
  mikePersistent = services.home-storage-root-persistent-mike;
  mikeTemporary = services.home-storage-root-temporary-mike;
  mikeBuckets = services.home-storage-buckets-mike;
  mikeLayout = services.home-storage-layout-mike;
  mikeReplay = services.home-generation-replay-mike;
  userGate = services."home-storage-user@";
  replayExecutable = builtins.head (lib.splitString " " mikeReplay.serviceConfig.ExecStart);
  marker = "/persist/home/mike/control/current/temporary-default";
  mountCommands = [
    mikePersistent.serviceConfig.ExecStart
    mikeTemporary.serviceConfig.ExecStart
  ]
  ++ mikeBuckets.serviceConfig.ExecStart;

  checks = {
    missing-policy-selects-persistent = mikePersistent.unitConfig.ConditionPathExists == "!${marker}";
    marker-selects-temporary = mikeTemporary.unitConfig.ConditionPathExists == marker;
    fixed-layout-is-provisioned = lib.all (path: settings ? ${path}) [
      "/persist/home/mike/root"
      "/persist/home/mike/paths"
      "/persist/home/mike/control"
      "/volatile/home/mike/root"
      "/volatile/home/mike/paths"
      "/persist/home/mike/root/.storage/control"
      "/volatile/home/mike/root/.storage/control"
    ];
    mount-arguments-are-fixed = lib.all (
      command:
      lib.hasInfix "/home/mike" command
      && !lib.hasInfix "layout.conf" command
      && !lib.hasInfix "temporary-default" command
    ) mountCommands;
    detailed-policy-runs-as-user =
      mikeLayout.serviceConfig.User == "mike"
      && mikeLayout.serviceConfig.NoNewPrivileges
      && lib.hasInfix "/persist/home/mike/control/current/layout.conf" mikeLayout.serviceConfig.ExecStart;
    policy-writes-are-confined = mikeLayout.serviceConfig.ProtectSystem == "strict";
    replay-runs-as-user =
      mikeReplay.serviceConfig.User == "mike"
      && mikeReplay.serviceConfig.ProtectSystem == "strict"
      && lib.elem "home-storage-layout-mike.service" mikeReplay.requires;
    replay-writes-are-confined = mikeReplay.serviceConfig.ReadWritePaths == [ "/home/mike" ];
    replay-has-no-privilege-escalation =
      mikeReplay.serviceConfig.NoNewPrivileges
      && (mikeReplay.serviceConfig.CapabilityBoundingSet or [ ]) == [ ];
    replay-identity-is-inventory-owned = lib.hasSuffix " mike /home/mike" mikeReplay.serviceConfig.ExecStart;
    replay-does-not-disrupt-live-sessions = !mikeReplay.restartIfChanged;
    preparation-only-attempts-fixed-mounts =
      lib.elem "home-storage-buckets-mike.service" services.home-storage-prepare.wants
      && !lib.elem "home-storage-layout-mike.service" services.home-storage-prepare.wants
      && !lib.elem "home-generation-replay-mike.service" services.home-storage-prepare.wants;
    mount-target-container-is-inventory-owned =
      settings."/persist/home/mike/root/.storage".d.user == "mike"
      && settings."/persist/home/mike/root/.storage".d.mode == "0700";
    prepare-precedes-logins = lib.all (unit: lib.elem unit services.home-storage-prepare.before) [
      "systemd-user-sessions.service"
      "display-manager.service"
      "sshd.service"
      "user@1000.service"
    ];
    sessions-require-preparation = lib.elem "home-storage-prepare.service" services.systemd-user-sessions.requires;
    lingering-users-require-preparation = lib.elem "home-storage-prepare.service" services.linger-users.requires;
    user-managers-have-per-user-gate =
      lib.elem "home-storage-user@%i.service" services."user@".requires
      && lib.elem "home-storage-user@%i.service" services."user@".after
      && userGate.serviceConfig.NoNewPrivileges
      && userGate.serviceConfig.CapabilityBoundingSet == [ ]
      && userGate.serviceConfig.ProtectSystem == "strict"
      && userGate.serviceConfig.ProtectHome;
    no-daemon-or-broker =
      !(services ? home-storaged)
      && !(evaluated.config.users.users ? home-storage)
      && !lib.any (
        package: lib.getName package == "home-storage"
      ) evaluated.config.environment.systemPackages;
  };

  failures = lib.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
pkgs.runCommand "home-storage-contract"
  {
    failureCount = toString (lib.length failures);
    failureNames = lib.concatStringsSep "," failures;
  }
  ''
    if [ "$failureCount" != 0 ]; then
      echo "failed home-storage contracts: $failureNames" >&2
      exit 1
    fi

    armFixture() {
      fixtureHome=$1
      fixtureControl="$fixtureHome/.storage/control"
      fixtureId="$(basename ${fixtureGeneration})"
      mkdir -p "$fixtureControl/generations"
      ln -s ${fixtureGeneration} "$fixtureControl/generations/$fixtureId"
      ln -s "generations/$fixtureId/home-storage-policy" "$fixtureControl/current"
    }

    replayHome="$TMPDIR/replay-home"
    armFixture "$replayHome"
    mkdir -p "$TMPDIR/poison-config"
    XDG_CONFIG_HOME="$TMPDIR/poison-config" ${replayExecutable} mike "$replayHome"
    test "$(readlink -e "$replayHome/.nix-profile")" = "$(readlink -e ${fixtureGeneration}/home-path)"
    test "$(readlink "$replayHome/.nix-profile")" = "$replayHome/.local/state/nix/profiles/profile"
    test "$(readlink "$replayHome/.local/state/nix/profiles/profile")" = profile-1-link
    test "$(readlink -e "$replayHome/.local/state/nix/profiles/profile-1-link")" = "$(readlink -e ${fixtureGeneration}/home-path)"
    test "$(readlink -e "$replayHome/.bashrc")" = ${fixtureFile}
    test -L "$replayHome/.config/systemd/user/fixture.service"
    test "$(readlink -e "$replayHome/.local/state/home-manager/gcroots/current-home")" = ${fixtureGeneration}
    test -e "$replayHome/.boot-replayed"
    test -e "$replayHome/.config/.boot-replayed"
    test ! -e "$TMPDIR/poison-config/.boot-replayed"
    ${replayExecutable} mike "$replayHome"

    staleHome="$TMPDIR/stale-home"
    armFixture "$staleHome"
    mkdir -p "$staleHome/.local/state/home-manager/gcroots"
    ln -s ${oldFixtureGeneration} "$staleHome/.local/state/home-manager/gcroots/current-home"
    ln -s ${oldFixtureHomeFiles}/.obsolete "$staleHome/.obsolete"
    ${replayExecutable} mike "$staleHome"
    test ! -e "$staleHome/.obsolete"
    test ! -L "$staleHome/.obsolete"

    collisionHome="$TMPDIR/collision-home"
    armFixture "$collisionHome"
    printf '%s\n' collision > "$collisionHome/.bashrc"
    if ${replayExecutable} mike "$collisionHome"; then
      echo "home generation replay accepted an unmanaged collision" >&2
      exit 1
    fi
    test "$(cat "$collisionHome/.bashrc")" = collision
    test ! -e "$collisionHome/.config/systemd/user/fixture.service"

    symlinkHome="$TMPDIR/symlink-home"
    armFixture "$symlinkHome"
    ln -s ${foreignFile} "$symlinkHome/.bashrc"
    if ${replayExecutable} mike "$symlinkHome"; then
      echo "home generation replay accepted a foreign symlink" >&2
      exit 1
    fi
    test "$(readlink "$symlinkHome/.bashrc")" = ${foreignFile}
    test ! -e "$symlinkHome/.config/systemd/user/fixture.service"

    legacyHome="$TMPDIR/legacy-home"
    mkdir -p "$legacyHome/.storage/control/generations/legacy"
    ln -s generations/legacy "$legacyHome/.storage/control/current"
    ${replayExecutable} mike "$legacyHome"
    test ! -e "$legacyHome/.bashrc"

    unpublishedHome="$TMPDIR/unpublished-home"
    mkdir -p "$unpublishedHome/.storage/control"
    ${replayExecutable} mike "$unpublishedHome"
    test ! -e "$unpublishedHome/.bashrc"

    touch "$out"
  ''
