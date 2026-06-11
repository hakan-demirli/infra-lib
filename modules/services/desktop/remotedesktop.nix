{
  config,
  lib,
  pkgs,
  host ? null,
  cluster ? null,
  ...
}:
let
  sunshineLabel = if host == null then "false" else (host.labels.sunshine or "false");
  cfgMode = config.services.remotedesktop.modeOverride;
  effectiveMode = if cfgMode != null then cfgMode else sunshineLabel;
  enableAny = effectiveMode == "true" || effectiveMode == "headless";
  headless = effectiveMode == "headless";

  owner = if host == null then null else (host.ownership.owner or null);
  ownerUser = if owner == null || cluster == null then null else (cluster.users.${owner} or null);
  primaryAccount = if ownerUser == null then null else ownerUser.system_account;
  user = if primaryAccount == null then "REMOTEDESKTOP_USER_UNSET" else primaryAccount.username;

  cfg = config.services.remotedesktop;

  defaultEdidBase64 = "AP///////wBMLUBwAA4AAQEeAQOApV14Cqgzq1BFpScNSEi974BxT4HAgQCBgJUAqcCzANHACOgAMPJwWoCwWIoAUB10AAAeb8IAoKCgVVAwIDUAUB10AAAaAAAA/QAYeA//dwAKICAgICAgAAAA/ABTQU1TVU5HCiAgICAgAW4CA2fwXWEQHwQTBRQgISJdXl9gZWZiZD9AdXba28LDxMbHLAkHBxUHUFcHAGdUAIMBAADiAE/jBcMBbgMMAEAAmDwoAIABAgMEbdhdxAF4gFkCAADBNAvjBg0B5Q8B4PAf5QGLhJABb8IAoKCgVVAwIDUAUB10AAAaAAAAAAAAZw==";

  edidFirmware = pkgs.runCommand "remotedesktop-edid" { } ''
    mkdir -p $out/lib/firmware/edid
    echo '${cfg.edidBase64}' | ${pkgs.coreutils}/bin/base64 -d > $out/lib/firmware/edid/remotedesktop.bin
  '';

  remotedesktopHostPkgs = with pkgs; [
    sunshine
    libva-utils
    mesa-demos
    vulkan-tools
    wayland-utils
  ];
  remotedesktopClientPkgs = with pkgs; [
    moonlight-qt
  ];

  sunshineKmsConfFile = pkgs.writeText "sunshine.conf" ''
    capture = kms
    adapter_name = ${cfg.drmDevice}
    min_log_level = info
  '';
in
{
  options.services.remotedesktop = {
    modeOverride = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "false"
          "true"
          "headless"
        ]
      );
      default = null;
      description = "Overrides `host.labels.sunshine`.";
    };

    connector = lib.mkOption {
      type = lib.types.str;
      default = "DP-1";
      description = "DRM connector for the fake EDID monitor.";
    };

    resolution = lib.mkOption {
      type = lib.types.str;
      default = "1920x1080@60";
      description = "Fake EDID monitor resolution.";
    };

    drmDevice = lib.mkOption {
      type = lib.types.str;
      default = "/dev/dri/card0";
      description = "DRM device for the headless session (WLR_DRM_DEVICES).";
    };

    edidBase64 = lib.mkOption {
      type = lib.types.str;
      default = defaultEdidBase64;
      description = ''
        Base64 EDID blob written under /lib/firmware/edid/ and loaded via
        `drm.edid_firmware`. Default: Samsung Q800T 4K HDMI 2.1.
      '';
    };

    sessionExecStart = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.oneOf [
          lib.types.str
          lib.types.path
          lib.types.package
        ]
      );
      default = null;
      description = ''
        ExecStart for `remotedesktop.service`. Null leaves the unit
        without an ExecStart so the consumer can supply one.
      '';
    };
  };

  config = lib.mkIf enableAny (
    lib.mkMerge [
      {
        services.sunshine = {
          enable = true;
          autoStart = false;
          openFirewall = true;
          capSysAdmin = true;
        };

        systemd.services.sunshine-seed-creds = {
          description = "Seed Sunshine Web UI credentials";
          wantedBy = [ "multi-user.target" ];
          before = [ "sunshine.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = user;
            Group = "users";
          };
          script = ''
            ${pkgs.sunshine}/bin/sunshine --creds ${user} ${user}
          '';
        };

        environment.systemPackages =
          remotedesktopHostPkgs ++ lib.optionals (!headless) remotedesktopClientPkgs;
      }

      (lib.mkIf headless {
        hardware.firmware = [ edidFirmware ];
        boot.kernelParams = [
          "drm.edid_firmware=${cfg.connector}:edid/remotedesktop.bin"
          "video=${cfg.connector}:e"
        ];

        systemd = {
          defaultUnit = lib.mkForce "multi-user.target";
          services = {
            seatd.serviceConfig.Type = lib.mkForce "exec";

            sunshine-write-conf = {
              description = "Provision default sunshine.conf for KMS capture";
              wantedBy = [ "multi-user.target" ];
              before = [ "sunshine.service" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                User = user;
                Group = "users";
              };
              script = ''
                confdir="$HOME/.config/sunshine"
                mkdir -p "$confdir"
                if [ ! -s "$confdir/sunshine.conf" ]; then
                  install -m 0644 ${sunshineKmsConfFile} "$confdir/sunshine.conf"
                fi
              '';
            };

            remotedesktop = {
              description = "Headless Wayland + Sunshine remote desktop session";
              after = [ "seatd.service" ];
              requires = [ "seatd.service" ];
              serviceConfig = {
                Type = "simple";
                User = user;
                Group = "users";
                SupplementaryGroups = [
                  "video"
                  "render"
                  "input"
                  "seat"
                ];
                PAMName = "login";
                ExecStart = lib.mkIf (cfg.sessionExecStart != null) cfg.sessionExecStart;
                Restart = "no";
                KillMode = "control-group";
                KillSignal = "SIGTERM";
                TimeoutStopSec = 10;
              };
              wantedBy = [ ];
            };
          };
        };

        services.seatd.enable = true;
        users.users.${user}.extraGroups = [ "seat" ];

        security.sudo.extraRules = [
          {
            users = [ user ];
            commands = [
              {
                command = "/run/current-system/sw/bin/systemctl start remotedesktop";
                options = [ "NOPASSWD" ];
              }
              {
                command = "/run/current-system/sw/bin/systemctl stop remotedesktop";
                options = [ "NOPASSWD" ];
              }
              {
                command = "/run/current-system/sw/bin/systemctl is-active remotedesktop";
                options = [ "NOPASSWD" ];
              }
              {
                command = "/run/current-system/sw/bin/systemctl is-active --quiet remotedesktop";
                options = [ "NOPASSWD" ];
              }
              {
                command = "/run/current-system/sw/bin/systemctl cat remotedesktop";
                options = [ "NOPASSWD" ];
              }
            ];
          }
        ];
      })
    ]
  );
}
