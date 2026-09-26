{
  pkgs,
  self,
  ...
}:
let
  inherit (pkgs) lib;
  accounts = import (self + "/modules/lib/accounts.nix") { inherit lib; };

  tier = groups: {
    inherit groups;
    root_ssh = false;
    sudo.extra_rule = null;
    ssh.allowed = true;
  };
  systemAccount = username: groups: {
    inherit username groups;
    uid = 1000;
    shell = "bash";
  };

  cluster = {
    unixAccessTiers = {
      admin = tier [ "wheel" ];
      container = tier [ "docker" ];
      plain = tier [ ];
      rule = tier [ ] // {
        sudo.extra_rule = "/run/current-system/sw/bin/reboot";
      };
    };
    users = {
      admin.system_account = systemAccount "admin" [ "audio" ];
      archived = {
        system_account = systemAccount "archived" [ ];
        archived = true;
      };
      elsewhere = {
        system_account = systemAccount "elsewhere" [ ];
        allowed_hosts = [ "other" ];
      };
      service.system_account = null;
      container.system_account = systemAccount "container" [ ];
      member.system_account = systemAccount "member" [ "wheel" ];
      rule.system_account = systemAccount "rule" [ ];
      worker.system_account = systemAccount "worker" [ ];
    };
    usersOnHost.host = [
      {
        user = "admin";
        unix_tier = "admin";
        via_team = "team";
      }
      {
        user = "admin";
        unix_tier = "admin";
        via_team = null;
      }
      {
        user = "archived";
        unix_tier = "admin";
      }
      {
        user = "elsewhere";
        unix_tier = "admin";
      }
      {
        user = "service";
        unix_tier = "admin";
      }
      {
        user = "unknown";
        unix_tier = "admin";
      }
      {
        user = "container";
        unix_tier = "container";
      }
      {
        user = "member";
        unix_tier = "plain";
      }
      {
        user = "rule";
        unix_tier = "rule";
      }
      {
        user = "worker";
        unix_tier = "plain";
      }
    ];
  };

  onHost = accounts.onHost cluster "host";

  checks = {
    only-materialised-accounts-remain =
      lib.attrNames onHost == [
        "admin"
        "container"
        "member"
        "rule"
        "worker"
      ];
    grants-merge-per-user =
      map (grant: grant.via_team) onHost.admin.grants == [
        "team"
        null
      ];
    groups-merge-account-and-tier =
      onHost.admin.groups == [
        "audio"
        "wheel"
      ];
    wheel-tier-is-sudo-and-root = onHost.admin.sudo_capable && onHost.admin.root_capable;
    root-equivalent-group-is-root-without-sudo =
      onHost.container.root_capable && !onHost.container.sudo_capable;
    account-groups-grant-privilege = onHost.member.sudo_capable && onHost.member.root_capable;
    sudo-rule-is-sudo-and-root = onHost.rule.sudo_capable && onHost.rule.root_capable;
    unprivileged-tier-has-no-privilege = !onHost.worker.sudo_capable && !onHost.worker.root_capable;
    missing-host-has-no-accounts = accounts.onHost cluster "other-host" == { };
  };

  failures = lib.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
pkgs.runCommand "accounts" { failureNames = lib.concatStringsSep "," failures; } ''
  if [ -n "$failureNames" ]; then
    echo "failed account checks: $failureNames" >&2
    exit 1
  fi
  touch "$out"
''
