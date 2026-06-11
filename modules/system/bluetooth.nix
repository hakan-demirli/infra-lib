{ pkgs, ... }:
let
  bluetoothSleepState = pkgs.writeShellApplication {
    name = "bluetooth-sleep-state";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.systemd
    ];
    text = ''
      state_file=/run/bluetooth-sleep-state/adapters.tsv

      if (( $# != 1 )); then
        printf 'usage: %s save|restore\n' "$0" >&2
        exit 2
      fi

      case "$1" in
        save)
          temporary="$(mktemp "$state_file.XXXXXX")"
          trap 'rm -f "$temporary"' EXIT

          if ! busctl --system --timeout=5s \
            --allow-interactive-authorization=no --json=short \
            call org.bluez / org.freedesktop.DBus.ObjectManager \
            GetManagedObjects \
            | jq -r '
                .data[0]
                | to_entries[]
                | select(.value | has("org.bluez.Adapter1"))
                | .value["org.bluez.Adapter1"].Powered as $powered
                | if $powered.type == "b" then
                    [ .key, $powered.data ] | @tsv
                  else
                    error("org.bluez.Adapter1.Powered is not boolean")
                  end
              ' > "$temporary"; then
            exit 0
          fi

          mv -f "$temporary" "$state_file"
          trap - EXIT
          ;;
        restore)
          [[ -r "$state_file" ]] || exit 0

          while IFS=$'\t' read -r adapter powered; do
            case "$powered" in
              true|false) ;;
              *)
                printf 'Ignoring malformed Bluetooth state for %s\n' "$adapter" >&2
                continue
                ;;
            esac

            restored=false
            for ((attempt = 0; attempt < 20; attempt++)); do
              if busctl --system --timeout=250ms \
                --allow-interactive-authorization=no set-property \
                org.bluez "$adapter" org.bluez.Adapter1 Powered \
                b "$powered" 2>/dev/null; then
                restored=true
                break
              fi
              sleep 0.1
            done

            if [[ $restored == false ]]; then
              printf 'Could not restore Bluetooth power state for %s\n' \
                "$adapter" >&2
            fi
          done < "$state_file"
          ;;
        *)
          printf 'usage: %s save|restore\n' "$0" >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  services.blueman.enable = true;

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = false;
    settings = {
      General = {
        ControllerMode = "dual";
        FastConnectable = "true";
        Experimental = "true";
        KernelExperimental = "true";
      };
      Policy = {
        AutoEnable = "false";
      };
    };
  };

  systemd.services.bluetooth-sleep-state = {
    description = "Preserve Bluetooth power state across sleep";
    wants = [ "bluetooth.service" ];
    after = [ "bluetooth.service" ];
    before = [
      "sleep.target"
      "tlp-sleep.service"
    ];
    wantedBy = [ "sleep.target" ];
    unitConfig = {
      DefaultDependencies = "no";
      StopWhenUnneeded = true;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RuntimeDirectory = "bluetooth-sleep-state";
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
      ExecStart = "${bluetoothSleepState}/bin/bluetooth-sleep-state save";
      ExecStop = "${bluetoothSleepState}/bin/bluetooth-sleep-state restore";
    };
  };
}
