{ pkgs, self }:
let
  inherit (pkgs) lib;
  types = import (self + "/modules/lib/types.nix") { inherit lib; };
  inventory = import (self + "/modules/lib/inventory.nix") {
    inherit lib types;
    self = ./fixtures/subnet-routes;
  };
  acl = (self.lib.mkCodegen { inherit lib inventory; }).headscaleAcl { inherit pkgs; };
in
assert
  inventory.subnetRoutes == {
    router = [
      {
        id = "desk";
        ipv4 = "192.168.2.20";
        network = "lan";
        prefix = "192.168.2.20/32";
        router = "router";
        ports = [ 22 ];
        teams = [
          {
            team = "guests";
            ports = [ 22 ];
          }
        ];
        users = [ ];
      }
    ];
  };
pkgs.runCommand "subnet-routes" { nativeBuildInputs = [ pkgs.jq ]; } ''
  set -euo pipefail
  fail() { echo "FAIL: $*" >&2; exit 1; }

  grep -v '^//' ${acl}/policy.hujson > policy.json

  jq -e '.hosts == {"desk": "192.168.2.20/32"}' policy.json >/dev/null \
    || fail "hosts alias is not exactly the reachable routed host"
  jq -e '.autoApprovers == {"routes": {"192.168.2.20/32": ["tag:cluster-router"]}}' policy.json >/dev/null \
    || fail "route approval is not exactly the router cluster tag"
  jq -e '.groups["group:guests"] == ["guest@"] and (.groups | has("group:alumni") | not)' policy.json >/dev/null \
    || fail "team groups do not follow the active grants"
  jq -e '[.acls[] | select(any(.dst[]; startswith("desk:") or startswith("printer:")))]
    == [{"action": "accept", "proto": "tcp", "src": ["group:guests"], "dst": ["desk:22"]}]' policy.json >/dev/null \
    || fail "routed host rules are not exactly the active grants"
  [ "$(sort ${acl}/users | tr '\n' ' ')" = "guest owner " ] \
    || fail "users file is not the active policy principals"

  echo "SUBNET ROUTES VERIFIED"
  touch "$out"
''
