{ pkgs, ... }:
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

  resolveModule =
    ref:
    lib.findFirst lib.pathExists null [
      (consumerRoot + "/modules/roles/${ref}.nix")
      (consumerRoot + "/modules/services/${ref}.nix")
      (consumerRoot + "/modules/common/${ref}.nix")
      (consumerRoot + "/modules/${ref}.nix")
      (libRoot + "/modules/roles/${ref}.nix")
      (libRoot + "/modules/services/${ref}.nix")
      (libRoot + "/modules/common/${ref}.nix")
      (libRoot + "/modules/${ref}.nix")
    ];

  echoResolved = resolveModule "services/echo";
  libOnlyResolved = resolveModule "services/lib-only";
  consumerOnlyResolved = resolveModule "services/consumer-only";
  missingResolved = resolveModule "services/does-not-exist";

  isUnder =
    rootSlug: p:
    let
      ps = builtins.toString p;
    in
    p != null && lib.hasInfix "mr-root-${rootSlug}" ps;
in
pkgs.runCommand "lib-multiroot"
  {
    echoResolvesToConsumer = toString (isUnder "consumer" echoResolved);
    libOnlyResolvesToLib = toString (isUnder "lib" libOnlyResolved);
    consumerOnlyResolvesToConsumer = toString (isUnder "consumer" consumerOnlyResolved);
    missingIsNull = toString (missingResolved == null);

    echoResolvedPath = toString echoResolved;
    libOnlyResolvedPath = toString libOnlyResolved;
    consumerOnlyResolvedPath = toString consumerOnlyResolved;
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }
    pass() { echo "PASS: $*"; }

    [ "$echoResolvesToConsumer" = "1" ] \
      || fail "services/echo defined in both should resolve to consumer, got $echoResolvedPath"
    pass "shadowing: services/echo resolves to consumer (won over library)"

    [ "$libOnlyResolvesToLib" = "1" ] \
      || fail "services/lib-only should resolve to library, got $libOnlyResolvedPath"
    pass "fallback: services/lib-only resolves to library"

    [ "$consumerOnlyResolvesToConsumer" = "1" ] \
      || fail "services/consumer-only should resolve to consumer, got $consumerOnlyResolvedPath"
    pass "consumer-only: services/consumer-only resolves to consumer"

    [ "$missingIsNull" = "1" ] \
      || fail "non-existent module should resolve to null, did not"
    pass "missing: services/does-not-exist resolves to null"

    echo "LIB-MULTIROOT INVARIANTS VERIFIED"
    touch $out
  ''
