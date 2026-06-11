{ pkgs, ... }:
let
  inherit (pkgs) lib;

  testFile = pkgs.writeText "hello-cache" "hello from harmonia";

  hashPart =
    pkg: builtins.substring (builtins.stringLength builtins.storeDir + 1) 32 (toString pkg.outPath);

  sopsOptionStubs = {
    options.sops.secrets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
    };
    options.sops.defaultSopsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "harmonia";

  nodes = {
    cache_server =
      { pkgs, ... }:
      {
        imports = [
          sopsOptionStubs
          ../../../services/harmonia.nix
        ];

        environment.systemPackages = [ pkgs.nix ];
        nix.settings.allowed-users = [ "*" ];
        system.extraDependencies = [ testFile ];

      };
    client =
      { lib, ... }:
      {
        nix.settings = {
          require-sigs = false;
          substituters = lib.mkForce [ "http://cache_server:5101" ];
          experimental-features = [
            "nix-command"
            "flakes"
          ];
        };
      };
  };

  testScript = ''
    start_all()

    cache_server.wait_for_unit("harmonia-fallback-key.service")
    cache_server.wait_for_unit("harmonia.socket")
    cache_server.wait_for_open_port(5101)

    cache_server.succeed("curl -sf http://localhost:5101/nix-cache-info | grep 'StoreDir: /nix/store'")

    pub_key = cache_server.succeed("cat /var/lib/secrets/nix-serve-key.pub").strip()
    print(f"Cache public key: {pub_key}")

    narinfo = cache_server.succeed("curl -sf http://localhost:5101/${hashPart testFile}.narinfo")
    print(f"narinfo: {narinfo}")
    assert "StorePath: ${testFile}" in narinfo, "StorePath not found in narinfo"
    assert "Sig: fallback-" in narinfo, f"signature missing or wrong: {narinfo!r}"

    client.wait_until_succeeds("curl -sf http://cache_server:5101/nix-cache-info")
    client.succeed("nix copy --from http://cache_server:5101/ ${testFile}")
    client.succeed("grep 'hello from harmonia' ${testFile}")

    print("HARMONIA VERIFICATIONS PASSED")
  '';
}
