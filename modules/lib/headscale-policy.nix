{
  lib,
  hujson ? import ./hujson.nix { inherit lib; },
}:
let
  userPrincipal =
    username:
    if !builtins.isString username || username == "" then
      throw "headscale username must be a non-empty string"
    else
      let
        parts = lib.splitString "@" username;
        count = lib.length parts;
      in
      if count == 1 then
        "${username}@"
      else if count == 2 && builtins.head parts != "" then
        username
      else
        throw "headscale user principal must contain at most one @: ${username}";

  normalizeGroups =
    groups:
    if !builtins.isAttrs groups then
      throw "headscale policy groups must be an attribute set"
    else
      lib.mapAttrs (
        name: members:
        if !lib.hasPrefix "group:" name then
          throw "headscale group name must start with 'group:': ${name}"
        else if !builtins.isList members then
          throw "headscale group members must be a list: ${name}"
        else
          map userPrincipal members
      ) groups;

  normalizeOwner = owner: if lib.hasPrefix "group:" owner then owner else userPrincipal owner;

  normalizeTagOwners =
    tagOwners:
    if !builtins.isAttrs tagOwners then
      throw "headscale policy tagOwners must be an attribute set"
    else
      lib.mapAttrs (
        name: owners:
        if !lib.hasPrefix "tag:" name then
          throw "headscale tag owner name must start with 'tag:': ${name}"
        else if !builtins.isList owners then
          throw "headscale tag owners must be a list: ${name}"
        else if !lib.all builtins.isString owners then
          throw "headscale tag owners must be strings: ${name}"
        else
          map normalizeOwner owners
      ) tagOwners;
in
rec {
  inherit userPrincipal;

  mk =
    policy:
    if !builtins.isAttrs policy then
      throw "headscale policy must be an attribute set"
    else
      policy
      // lib.optionalAttrs (policy ? groups) {
        groups = normalizeGroups policy.groups;
      }
      // lib.optionalAttrs (policy ? tagOwners) {
        tagOwners = normalizeTagOwners policy.tagOwners;
      };

  write =
    {
      pkgs,
      name,
      policy,
      comments ? [ ],
    }:
    hujson.write {
      inherit pkgs name comments;
      value = mk policy;
    };
}
