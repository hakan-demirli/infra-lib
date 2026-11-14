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

    # Forgejo deletes a merged head branch only when the merge request asks for it.
    prune-merged-branches = effects.mkEffect {
      name = "prune-merged-branches";
      checkout = true;
      lock = "prune-merged-branches";
      inputs = [ pkgs.git ];
      effectScript = ''
        set -euo pipefail
        git fetch --quiet --prune --no-tags origin '+refs/heads/*:refs/remotes/origin/*'
        git for-each-ref --merged refs/remotes/origin/unstable \
          --format='%(refname:lstrip=3) %(objectname)' refs/remotes/origin |
          while read -r branch rev; do
            case $branch in
              HEAD | main | unstable) continue ;;
            esac
            echo "deleting merged branch $branch"
            git push --force-with-lease="refs/heads/$branch:$rev" origin ":refs/heads/$branch" ||
              echo "branch $branch moved; keeping it"
          done
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
