{
  lib,
  host ? null,
  ...
}:
let
  hi = if host == null then null else (host.impermanence or null);
  gate = hi != null && (hi.enable or false) && (hi.rollback_backend or "tmpfs") == "btrfs";
in
{
  config = lib.mkIf gate {
    boot.initrd = {
      systemd.enable = true;
      supportedFilesystems = [ "btrfs" ];
      systemd.services.rollback-root = {
        description = "Rollback btrfs root to blank snapshot";
        wantedBy = [ "initrd.target" ];
        after = [ "dev-root_vg-root.device" ];
        before = [ "sysroot.mount" ];
        unitConfig.DefaultDependencies = "no";
        serviceConfig.Type = "oneshot";
        script = ''
          set -euo pipefail

          mkdir -p /mnt
          mount -t btrfs -o subvol=/ /dev/root_vg/root /mnt

          delete_subvolume_tree() {
            local target="$1"
            local progress
            local children=()

            while true; do
              mapfile -t children < <(btrfs subvolume list -o "$target" | cut -f9- -d' ')
              ((''${#children[@]} == 0)) && break

              progress=0
              for subvol in "''${children[@]}"; do
                if btrfs subvolume delete "/mnt/$subvol"; then
                  progress=1
                fi
              done
              if ((progress == 0)); then
                echo "rollback-root: cannot remove nested subvolumes under $target" >&2
                return 1
              fi
            done

            btrfs subvolume delete "$target"
          }

          cleanup() {
            if [[ -e /mnt/root-old && ! -e /mnt/root ]]; then
              mv /mnt/root-old /mnt/root
            fi
            umount /mnt || true
          }
          trap cleanup EXIT

          btrfs subvolume show /mnt/root >/dev/null
          btrfs subvolume show /mnt/root-blank >/dev/null

          if [[ -e /mnt/root-next ]]; then
            btrfs subvolume show /mnt/root-next >/dev/null
            delete_subvolume_tree /mnt/root-next
          fi
          if [[ -e /mnt/root-old ]]; then
            btrfs subvolume show /mnt/root-old >/dev/null
            delete_subvolume_tree /mnt/root-old
          fi

          btrfs subvolume snapshot /mnt/root-blank /mnt/root-next
          btrfs subvolume show /mnt/root-next >/dev/null

          mv /mnt/root /mnt/root-old
          mv /mnt/root-next /mnt/root

          trap - EXIT

          if ! delete_subvolume_tree /mnt/root-old; then
            echo "rollback-root: new root is active, but stale root-old cleanup failed" >&2
          fi
          umount /mnt
        '';
      };
    };
  };
}
