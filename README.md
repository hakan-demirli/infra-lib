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
