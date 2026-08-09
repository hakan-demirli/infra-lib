{ pkgs, self }:
let
  inherit (pkgs) lib;

  mkModulesRoot =
    name: files:
    let
      writes = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          relPath: content:
          let
            slug = lib.replaceStrings [ "/" ] [ "-" ] relPath;
            src = pkgs.writeText "mr-${name}-${slug}" content;
          in
          ''
            install -D -m 0644 ${src} "$out/modules/${relPath}"
          ''
        ) files
      );
    in
    pkgs.runCommand "mr-root-${name}" { } ''
      mkdir -p $out/modules
      ${writes}
    '';

  libRoot = mkModulesRoot "lib" {
    "services/echo.nix" = ''
      { ... }: { _module.args.echoFrom = "library"; }
    '';
    "services/lib-only.nix" = ''
      { ... }: { _module.args.libOnlyFrom = "library"; }
    '';
  };

  consumerRoot = mkModulesRoot "consumer" {
    "services/echo.nix" = ''
      { ... }: { _module.args.echoFrom = "consumer"; }
    '';
    "services/consumer-only.nix" = ''
      { ... }: { _module.args.consumerOnlyFrom = "consumer"; }
    '';
  };

  builder = import (self + "/modules/lib/mkHost.nix") {
    inputs = { };
    self = consumerRoot;
    inherit lib libRoot;
    inventory = {
      deploymentRoles = { };
      hosts = { };
    };
  };

  selfEchoResolved = builder.resolveModule "self:services/echo";
  infraEchoResolved = builder.resolveModule "infra:services/echo";
  libOnlyResolved = builder.resolveModule "infra:services/lib-only";
  consumerOnlyResolved = builder.resolveModule "self:services/consumer-only";
  unqualifiedAttempt = builtins.tryEval (builder.resolveModule "services/echo");
  traversalAttempt = builtins.tryEval (builder.resolveModule "self:services/../../outside");
  missingAttempt = builtins.tryEval (builder.resolveModule "infra:services/does-not-exist");

  isUnder =
    rootSlug: p:
    let
      ps = builtins.toString p;
    in
    p != null && lib.hasInfix "mr-root-${rootSlug}" ps;
in
pkgs.runCommand "explicit-module-resolution"
  {
    selfEchoResolvesToConsumer = toString (isUnder "consumer" selfEchoResolved);
    infraEchoResolvesToLibrary = toString (isUnder "lib" infraEchoResolved);
    libOnlyResolvesToLib = toString (isUnder "lib" libOnlyResolved);
    consumerOnlyResolvesToConsumer = toString (isUnder "consumer" consumerOnlyResolved);
    unqualifiedThrew = toString (!unqualifiedAttempt.success);
    traversalThrew = toString (!traversalAttempt.success);
    missingThrew = toString (!missingAttempt.success);

    selfEchoResolvedPath = toString selfEchoResolved;
    infraEchoResolvedPath = toString infraEchoResolved;
    libOnlyResolvedPath = toString libOnlyResolved;
    consumerOnlyResolvedPath = toString consumerOnlyResolved;
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }
    pass() { echo "PASS: $*"; }

    [ "$selfEchoResolvesToConsumer" = "1" ] \
      || fail "self:services/echo should resolve to the consumer, got $selfEchoResolvedPath"
    pass "self: prefix resolves to the consumer"

    [ "$infraEchoResolvesToLibrary" = "1" ] \
      || fail "infra:services/echo should resolve to the library, got $infraEchoResolvedPath"
    pass "infra: prefix resolves to the library without shadowing"

    [ "$libOnlyResolvesToLib" = "1" ] \
      || fail "services/lib-only should resolve to library, got $libOnlyResolvedPath"
    pass "fallback: services/lib-only resolves to library"

    [ "$consumerOnlyResolvesToConsumer" = "1" ] \
      || fail "services/consumer-only should resolve to consumer, got $consumerOnlyResolvedPath"
    pass "consumer-only: services/consumer-only resolves to consumer"

    [ "$unqualifiedThrew" = "1" ] \
      || fail "unqualified module reference should throw"
    pass "unqualified module reference throws"

    [ "$traversalThrew" = "1" ] \
      || fail "module path traversal should throw"
    pass "module path traversal throws"

    [ "$missingThrew" = "1" ] \
      || fail "non-existent module should throw, did not"
    pass "missing explicit module throws"

    echo "EXPLICIT MODULE RESOLUTION VERIFIED"
    touch $out
  ''
