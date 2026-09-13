_: {
  perSystem =
    { pkgs, ... }:
    {
      checks.ci-policy =
        pkgs.runCommand "check-ci-policy"
          {
            src = pkgs.lib.fileset.toSource {
              root = ../../../..;
              fileset = ../../../../.github;
            };
            nativeBuildInputs = [
              pkgs.actionlint
              pkgs.shellcheck
            ];
          }
          ''
            cd "$src"
            actionlint .github/workflows/*.yml
            touch "$out"
          '';
    };
}
