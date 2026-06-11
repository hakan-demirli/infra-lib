#!/usr/bin/env bash

if (( $# != 2 )); then
  echo "usage: home-generation-replay USER HOME" >&2
  exit 2
fi

username=$1
home=$2
control="$home/.storage/control"

if [[ ! -e "$control/current" && ! -L "$control/current" ]]; then
  echo "home-generation-replay: $username has no published generation; skipping"
  exit 0
fi

if [[ ! -L "$control/current" ]]; then
  echo "home-generation-replay: $control/current is not a generation link" >&2
  exit 1
fi

current_target=$(readlink "$control/current")
case "$current_target" in
  generations/*/home-storage-policy)
    generation_id="${current_target#generations/}"
    generation_id="${generation_id%/home-storage-policy}"
    ;;
  generations/*)
    legacy_id="${current_target#generations/}"
    if [[ -n "$legacy_id" && "$legacy_id" != */* ]]; then
      echo "home-generation-replay: $username still uses a legacy policy; skipping"
      exit 0
    fi
    echo "home-generation-replay: invalid current target: $current_target" >&2
    exit 1
    ;;
  *)
    echo "home-generation-replay: invalid current target: $current_target" >&2
    exit 1
    ;;
esac

if [[ -z "$generation_id" || "$generation_id" == */* ]]; then
  echo "home-generation-replay: invalid generation ID: $generation_id" >&2
  exit 1
fi

generation=$(readlink -e "$control/generations/$generation_id")
case "$generation" in
  /nix/store/*-home-manager-generation) ;;
  *)
    echo "home-generation-replay: generation is not an immutable Home Manager closure" >&2
    exit 1
    ;;
esac

home_files=$(readlink -e "$generation/home-files" 2>/dev/null || true)
profile_directory="$home/.local/state/nix/profiles"
if [[ -z "$home_files" || ! -d "$home_files" || ! -d "$generation/home-path" || ! -x "$generation/boot-replay" ]]; then
  echo "home-generation-replay: incomplete generation: $generation" >&2
  exit 1
fi

check_managed() {
  local source=$1
  local target=$2
  local current_source

  if [[ -e "$target" || -L "$target" ]]; then
    if [[ -f "$target" ]] && cmp -s "$source" "$target"; then
      return
    fi
    if [[ -L "$target" ]]; then
      current_source=$(readlink "$target")
      case "$current_source" in
        /nix/store/*-home-manager-files/*) return ;;
      esac
    fi
    echo "home-generation-replay: refusing unmanaged collision at $target" >&2
    exit 1
  fi
}

check_managed_link() {
  local target=$1
  local expected=$2
  local resolved_suffix=$3
  local current_source resolved

  if [[ ! -e "$target" && ! -L "$target" ]]; then
    return
  fi
  if [[ -L "$target" ]]; then
    current_source=$(readlink "$target")
    if [[ -n "$expected" && "$current_source" == "$expected" ]]; then
      return
    fi
    resolved=$(readlink -e "$target" 2>/dev/null || true)
    if [[ -n "$resolved_suffix" && "$resolved" == /nix/store/*-"$resolved_suffix" ]]; then
      return
    fi
  fi

  echo "home-generation-replay: refusing unmanaged collision at $target" >&2
  exit 1
}

link_managed() {
  local source=$1
  local target=$2
  ln -sfnT "$source" "$target"
}

declare -A parent_directories=()
while IFS= read -r -d "" source; do
  relative="${source#"$home_files"/}"
  case "$relative" in
    .storage|.storage/*)
      echo "home-generation-replay: generation attempts to manage reserved path $relative" >&2
      exit 1
      ;;
  esac
  check_managed "$source" "$home/$relative"
  parent_directories["$(dirname "$home/$relative")"]=1
done < <(find "$home_files" \( -type f -o -type l \) -print0)

check_managed_link "$profile_directory/profile-1-link" "" "home-manager-path"
check_managed_link "$profile_directory/profile" "profile-1-link" ""
check_managed_link "$home/.nix-profile" "$profile_directory/profile" ""
check_managed_link "$home/.local/state/home-manager/gcroots/current-home" "" "home-manager-generation"

old_generation=$(readlink -e "$home/.local/state/home-manager/gcroots/current-home" 2>/dev/null || true)
case "$old_generation" in
  /nix/store/*-home-manager-generation)
    if [[ "$old_generation" != "$generation" ]]; then
      old_home_files=$(readlink -e "$old_generation/home-files" 2>/dev/null || true)
      if [[ -n "$old_home_files" && -d "$old_home_files" ]]; then
        while IFS= read -r -d "" old_source; do
          relative="${old_source#"$old_home_files"/}"
          case "$relative" in
            .storage | .storage/*) continue ;;
          esac

          if [[ ! -e "$home_files/$relative" && ! -L "$home_files/$relative" ]]; then
            target="$home/$relative"
            current_source=$(readlink "$target" 2>/dev/null || true)
            case "$current_source" in
              /nix/store/*-home-manager-files/*) rm -- "$target" ;;
            esac
          fi
        done < <(find "$old_home_files" \( -type f -o -type l \) -print0)
      fi
    fi
    ;;
esac

parent_directories["$home"]=1
parent_directories["$home/.local/state/home-manager/gcroots"]=1
parent_directories["$profile_directory"]=1
mkdir -p "${!parent_directories[@]}"

while IFS= read -r -d "" source; do
  relative="${source#"$home_files"/}"
  link_managed "$source" "$home/$relative"
done < <(find "$home_files" \( -type f -o -type l \) -print0)

link_managed "$generation/home-path" "$profile_directory/profile-1-link"
link_managed "profile-1-link" "$profile_directory/profile"
link_managed "$profile_directory/profile" "$home/.nix-profile"
link_managed "$generation" "$home/.local/state/home-manager/gcroots/current-home"

env \
  -u DBUS_SESSION_BUS_ADDRESS \
  -u DCONF_PROFILE \
  HOME="$home" \
  USER="$username" \
  LOGNAME="$username" \
  XDG_CONFIG_HOME="$home/.config" \
  XDG_DATA_HOME="$home/.local/share" \
  XDG_STATE_HOME="$home/.local/state" \
  XDG_CACHE_HOME="$home/.cache" \
  "$generation/boot-replay"
echo "home-generation-replay: restored $generation"
