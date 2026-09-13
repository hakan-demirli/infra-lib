{ inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      checks.ci-policy =
        pkgs.runCommand "check-ci-policy"
          {
            src = inputs.self;
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
