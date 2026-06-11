# infra-lib

Reusable NixOS library for inventory-driven infra management.

## Use

```nix
{
  inputs.infra-lib.url = "github:hakan-demirli/infra-lib";

  outputs = { self, nixpkgs, infra-lib, ... }@inputs: let
    lib       = nixpkgs.lib;
    types     = infra-lib.lib.types       { inherit lib; };
    inventory = infra-lib.lib.mkInventory { inherit lib self types; };
    builder   = infra-lib.lib.mkRole {
      inherit inputs self lib inventory;
      libRoot = infra-lib;
    };
  in {
    nixosConfigurations  = builder.nixosConfigurations;
    darwinConfigurations = builder.darwinConfigurations;
  };
}
```

## Test

```bash
nix flake check
```

## User-managed home storage

`impermanence.home_mode = "user-managed"` keeps `/home` in the rolled-back
root while provisioning persistent and volatile backing trees for each granted
system user. Missing policy always defaults to a conventional persistent home.

The system mounts fixed paths before logins are enabled:

```text
/persist/home/<user>/{root,paths,control}
/volatile/home/<user>/{root,paths}
/home/<user>/.storage/{persistent,temporary,control}
```

Users publish policy through standalone Home Manager without sudo:

```nix
homeStorage = {
  enable = true;
  default = "temporary";
  paths.Desktop = "persistent";
};
```

Home Manager atomically selects an immutable generation in the persistent
control bucket. At boot root checks only whether its fixed
`temporary-default` marker exists and performs inventory-generated bind mounts.
The detailed `layout.conf` is interpreted by `systemd-tmpfiles` as the target
user with write access limited to that user's home and backing directories.

When `current` selects a complete Home Manager generation, the system restores
its home files, package profile, user units, and boot payload before user
sessions start. Replay runs as the inventory user with no privileges and with
writes confined to that user's home. Root-owned mount services never accept
user-provided source or target paths, and each user's backing and control
directories are private to that UID. Only fixed mounts participate in global
login preparation; layout and replay failures gate that user's manager without
blocking other users.

Focused verification:

```bash
nix build .#checks.x86_64-linux.test-home-storage-contract
nix build .#checks.x86_64-linux.test-home-storage-vm
```
