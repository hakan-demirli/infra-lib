{
  pkgs,
  self,
  inputs,
}:
let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  evalModule =
    module: extraModule:
    (inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit inputs;
        host = null;
        cluster = null;
      };
      modules = [
        inputs.impermanence.nixosModules.impermanence
        (self + module)
        {
          boot.isContainer = true;
          system.stateVersion = "26.05";
        }
        extraModule
      ];
    }).config;

  hasFailure =
    needle: evaluated:
    lib.any (
      assertion: !assertion.assertion && lib.hasInfix needle assertion.message
    ) evaluated.assertions;

  roleIdentity = evalModule "/modules/common/role-identity.nix" { };
  bluetooth = evalModule "/modules/system/bluetooth.nix" { };
  bluetoothSleepState = bluetooth.systemd.services.bluetooth-sleep-state;
  bluetoothStateTool = lib.removeSuffix " save" bluetoothSleepState.serviceConfig.ExecStart;
  tailscaleAuth = evalModule "/modules/services/tailscale.nix" {
    imports = [ inputs.sops-nix.nixosModules.sops ];
    networking.useHostResolvConf = lib.mkForce false;
    services.tailscale = {
      loginServerHost = "headscale.example";
      useAuthKey = false;
      authKeyFile = "/run/keys/tailscale";
      authKeyParameters.ephemeral = true;
    };
  };
  tailscaleAutoconnect = tailscaleAuth.systemd.services.tailscaled-autoconnect;
  mungeSops = evalModule "/modules/services/munge-sops.nix" (
    { lib, ... }:
    {
      options.sops.secrets = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options.path = lib.mkOption { type = lib.types.str; };
          }
        );
        default = { };
      };
      config = {
        services.munge.enable = true;
        sops.secrets."munge-key".path = "/run/secrets/munge-key";
      };
    }
  );
  mungeService = mungeSops.systemd.services.munged;

  checks = {
    role-identity-does-not-mask-persistent-state = !(roleIdentity.fileSystems ? "/persist/system");
    bluetooth-keeps-explicit-power-policy =
      bluetooth.hardware.bluetooth.enable
      && !bluetooth.hardware.bluetooth.powerOnBoot
      && bluetooth.hardware.bluetooth.settings.Policy.AutoEnable == "false";
    bluetooth-preserves-state-around-sleep =
      lib.elem "bluetooth.service" bluetoothSleepState.wants
      && lib.elem "bluetooth.service" bluetoothSleepState.after
      && lib.elem "tlp-sleep.service" bluetoothSleepState.before
      && lib.elem "sleep.target" bluetoothSleepState.before
      && bluetoothSleepState.wantedBy == [ "sleep.target" ]
      && bluetoothSleepState.unitConfig.StopWhenUnneeded
      && bluetoothSleepState.serviceConfig.Type == "oneshot"
      && bluetoothSleepState.serviceConfig.RemainAfterExit
      && bluetoothSleepState.serviceConfig.RuntimeDirectoryMode == "0700";
    tailscale-auth-key-stays-file-backed =
      tailscaleAuth.services.tailscale.extraUpFlags == [
        "--reset"
        "--login-server=https://headscale.example"
      ]
      && tailscaleAutoconnect.serviceConfig.LoadCredential == [ "auth-key:/run/keys/tailscale" ]
      && tailscaleAutoconnect.serviceConfig.TimeoutStartSec == "60s"
      && lib.hasInfix ''--auth-key "file:$auth_key_file"'' tailscaleAutoconnect.script
      && lib.hasInfix "--force-reauth" tailscaleAutoconnect.script
      && lib.hasInfix "/var/lib/tailscale/bootstrap-auth-key.sha256" tailscaleAutoconnect.script
      && lib.hasInfix ''runtime_auth_key="$RUNTIME_DIRECTORY/auth-key"'' tailscaleAutoconnect.script
      && lib.hasInfix "?ephemeral=true" tailscaleAutoconnect.script
      && !lib.hasInfix "cat /run/keys/tailscale" tailscaleAutoconnect.script
      && !lib.any (lib.hasPrefix "--advertise-tags") tailscaleAuth.services.tailscale.extraUpFlags;
    munge-sops-uses-owned-runtime-key =
      mungeSops.services.munge.password == "/run/munge/munge.key"
      && lib.elem "sops-install-secrets.service" mungeService.after
      && lib.elem "sops-install-secrets.service" mungeService.requires
      && lib.length mungeService.serviceConfig.ExecStartPre == 1
      && lib.hasPrefix "+" (lib.head mungeService.serviceConfig.ExecStartPre)
      && lib.hasInfix "-o munge -g munge -m 0400 /run/secrets/munge-key /run/munge/munge.key" (
        lib.head mungeService.serviceConfig.ExecStartPre
      );
    reverse-ssh-client-disabled-payload = hasFailure "payload is configured" (
      evalModule "/modules/services/reverse-ssh-client.nix" {
        services.reverse-ssh-client.remoteHost = "gateway.example";
      }
    );
    reverse-ssh-server-disabled-payload = hasFailure "requires enable=true" (
      evalModule "/modules/services/reverse-ssh-server.nix" {
        services.reverse-ssh-server.allowedTCPPorts = [ 2200 ];
      }
    );
    github-runner-disabled-payload = hasFailure "payload is configured" (
      evalModule "/modules/services/github-runner.nix" {
        cluster.githubRunner.url = "https://github.com/example";
      }
    );
    headscale-disabled-payload = hasFailure "payload is configured" (
      evalModule "/modules/services/headscale.nix" {
        services.headscale-server.serverUrl = "headscale.example";
      }
    );
    auto-upgrade-disabled-payload = hasFailure "payload is configured" (
      evalModule "/modules/common/auto-upgrade.nix" {
        cluster.autoUpgrade.onCalendar = "hourly";
      }
    );
    server-base-disabled-payload = hasFailure "requires system.server.enable=true" (
      evalModule "/modules/system/server-base.nix" {
        system.server = {
          enable = false;
          hostName = "ignored.example";
        };
      }
    );
    slurm-metrics-disabled-payload = hasFailure "requires enable=true" (
      evalModule "/modules/services/slurm-metrics.nix" {
        services.cluster-slurm-metrics.listenPort = 9999;
      }
    );
    ceph-exporter-disabled-payload = hasFailure "payload is configured" (
      evalModule "/modules/services/ceph-exporter.nix" {
        services.cluster-ceph-exporter.mgrInstance = "mgr-0";
      }
    );
    remotedesktop-disabled-payload = hasFailure "must be set exactly when mode is headless" (
      evalModule "/modules/services/desktop/remotedesktop.nix" {
        services.remotedesktop.connector = "HDMI-A-1";
      }
    );
  };

  failures = lib.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
pkgs.runCommand "module-contracts"
  {
    failureCount = toString (lib.length failures);
    failureNames = lib.concatStringsSep "," failures;
    inherit bluetoothStateTool;
    tailscaleSystem = tailscaleAuth.system.build.toplevel;
    mungeSystem = mungeSops.system.build.toplevel;
  }
  ''
    if [ "$failureCount" != 0 ]; then
      echo "failed module contracts: $failureNames" >&2
      exit 1
    fi
    test -x "$bluetoothStateTool"
    grep -q GetManagedObjects "$bluetoothStateTool"
    grep -q org.bluez.Adapter1 "$bluetoothStateTool"
    if grep -q /org/bluez/hci "$bluetoothStateTool"; then
      echo "Bluetooth state helper hardcodes an adapter path" >&2
      exit 1
    fi
    test -e "$tailscaleSystem"
    test -e "$mungeSystem"
    touch "$out"
  ''
