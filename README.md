# infra-lib

`infra-lib` turns typed inventory into NixOS/Darwin configurations and policy artifacts (e.g. SOPS rules, Headscale ACLs, Matchbox profiles).

## Integrate

```nix
{
  inputs.infra-lib.url = "github:hakan-demirli/infra-lib";

  outputs = { self, nixpkgs, infra-lib, ... }@inputs:
    let
      lib = nixpkgs.lib;
      types = infra-lib.lib.types { inherit lib; };
      inventory = infra-lib.lib.mkInventory { inherit lib self types; };
      hosts = infra-lib.lib.mkHost { inherit inputs self lib inventory; libRoot = infra-lib; };
    in {
      inherit (hosts) nixosConfigurations darwinConfigurations;
    };
}
```

## Authority

Inventory keeps four authority axes separate:

- Deployment roles choose modules and secret buckets (e.g. `infra:system/base`, `self:services/sops`).
- Topology roles describe operational placement without choosing modules (e.g. `compute`, `controller`).
- Unix tiers grant local access without global authority (e.g. groups, sudo, SSH, root keys).
- Admin scopes grant global authority without local access (e.g. `fleet`, `tailnet`).
- Headscale policy uses topology and Tailnet authority but never tags nodes. Enrolment assigns only `tag:bootstrap`, and promotion is manual.

## Home Storage

`user-managed` storage lets an unprivileged Home Manager policy select persistent paths (e.g. persist `Desktop` while keeping other state temporary).

```nix
homeStorage = {
  enable = true;
  default = "temporary";
  paths.Desktop = "persistent";
};
```
