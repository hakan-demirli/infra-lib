{ lib, nixbot }:
{
  pkgs,
  primaryRepo,
  bot,
  update,
}:
let
  source = pkgs.applyPatches {
    name = "nixbot-source";
    src = nixbot;
    patches = [ ./patches/nixbot-flake-update-fast-forward-only.patch ];
  };
  effects = import "${source}/herculesCI/effects-lib.nix" { inherit pkgs; };
in
{
  onPush.default.outputs.effects = lib.optionalAttrs (primaryRepo.branch == "unstable") {
    promote-main = effects.mkEffect {
      name = "promote-main";
      checkout = true;
      lock = "promote-main";
      inputs = [ pkgs.git ];
      effectScript = ''
        set -euo pipefail
        candidate=${primaryRepo.rev}
        main=$(git ls-remote --exit-code origin refs/heads/main | cut -f1)
        unstable=$(git ls-remote --exit-code origin refs/heads/unstable | cut -f1)
        git fetch --quiet --no-tags origin "$main" "$unstable"
        if git merge-base --is-ancestor "$candidate" "$main"; then
          echo "$candidate is already on main"
          exit 0
        fi
        git merge-base --is-ancestor "$main" "$candidate"
        git merge-base --is-ancestor "$candidate" "$unstable"
        git push origin "$candidate:refs/heads/main"
      '';
    };
  };

  onSchedule.update-flake-inputs = {
    when = update;
    outputs.effects.update =
      (effects.flakeUpdate {
        forgeType = "gitea";
        updateBranch = "automation/update-flake-inputs";
        # Each run starts over from the channel instead of reusing a stale branch.
        baseMergeBranch = "unstable";
        baseMergeMethod = "reset";
        autoMergeMethod = "fast-forward-only";
        pullRequestTitle = "chore: update flake inputs";
        commitSummary = "chore: update flake inputs";
      }).overrideAttrs
        {
          GIT_AUTHOR_NAME = bot.name;
          GIT_AUTHOR_EMAIL = bot.email;
          GIT_COMMITTER_NAME = bot.name;
          GIT_COMMITTER_EMAIL = bot.email;
        };
  };
}
