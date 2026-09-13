{ inputs, ... }:
{
  flake.githubActions = inputs.nix-github-actions.lib.mkGithubMatrix {
    inherit (inputs.self) checks;
    platforms = {
      x86_64-linux = "ubuntu-24.04";
      aarch64-linux = "ubuntu-24.04-arm";
      aarch64-darwin = "macos-14";
    };
  };
}
