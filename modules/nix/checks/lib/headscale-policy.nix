{ pkgs, self }:
let
  inherit (self.lib) headscalePolicy;

  policyFile = headscalePolicy.write {
    inherit pkgs;
    name = "headscale-policy-test.hujson";
    comments = [ "policy fixture" ];
    policy = {
      groups."group:admin" = [
        "owner"
        "person@example.com"
      ];
      tagOwners."tag:server" = [
        "group:admin"
        "owner"
      ];
      acls = [
        {
          action = "accept";
          src = [ "group:admin" ];
          dst = [ "tag:server:*" ];
        }
      ];
    };
  };

  rejects = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  rejectsMultipleAt = rejects (headscalePolicy.mk { groups."group:test" = [ "bad@@principal" ]; });
  rejectsInvalidGroup = rejects (headscalePolicy.mk { groups.test = [ "owner" ]; });
  rejectsInvalidTag = rejects (headscalePolicy.mk { tagOwners.server = [ "owner" ]; });
  rejectsInvalidName = rejects (
    headscalePolicy.write {
      inherit pkgs;
      name = "policy.json";
      policy = { };
    }
  );
in
pkgs.runCommand "headscale-policy"
  {
    nativeBuildInputs = [ pkgs.jq ];
    inherit policyFile;
    rejectsMultipleAt = if rejectsMultipleAt then "yes" else "no";
    rejectsInvalidGroup = if rejectsInvalidGroup then "yes" else "no";
    rejectsInvalidTag = if rejectsInvalidTag then "yes" else "no";
    rejectsInvalidName = if rejectsInvalidName then "yes" else "no";
  }
  ''
    grep -Fqx '// policy fixture' "$policyFile"
    grep -v '^//' "$policyFile" \
      | jq -e '.groups["group:admin"] == ["owner@", "person@example.com"]' >/dev/null
    grep -v '^//' "$policyFile" \
      | jq -e '.tagOwners["tag:server"] == ["group:admin", "owner@"]' >/dev/null

    test "$rejectsMultipleAt" = yes
    test "$rejectsInvalidGroup" = yes
    test "$rejectsInvalidTag" = yes
    test "$rejectsInvalidName" = yes

    touch "$out"
  ''
