{
  pkgs,
  cephPkgs ? pkgs,
  self,
  inputs,
  ...
}:
{
  inventory-validation = import ./inventory-validation.nix { inherit pkgs self; };
  deployment-role-secrets = import ./deployment-role-secrets.nix { inherit pkgs self; };
  disko-wiring = import ./disko-wiring.nix { inherit pkgs self; };
  disko-installer-contract = import ./disko-installer-contract.nix { inherit pkgs self; };
  impermanence-contract = import ./impermanence-contract.nix {
    inherit pkgs self inputs;
  };
  home-storage-contract = import ./home-storage-contract.nix {
    inherit pkgs self inputs;
  };
  home-storage-vm = import ./home-storage-vm.nix {
    inherit pkgs self;
  };
  module-contracts = import ./module-contracts.nix {
    inherit pkgs self inputs;
  };
  explicit-module-resolution = import ./explicit-module-resolution.nix { inherit pkgs self; };
  cluster-fs-modules-smoke = import ./cluster-fs-modules-smoke.nix { inherit pkgs self; };
  mkhost-determinism = import ./mkhost-determinism.nix { inherit pkgs self; };
  ssh-key-rotation = import ./ssh-key-rotation.nix { inherit pkgs self; };
  user-offboarding = import ./user-offboarding.nix { inherit pkgs self; };
  virt-host-smoke = import ./virt-host-smoke.nix { inherit pkgs self; };
  headscale-ha-shared-state-via-postgres = import ./headscale-ha-shared-state-via-postgres.nix {
    inherit pkgs;
  };
  headscale-policy = import ./headscale-policy.nix { inherit pkgs self; };
  headscale-codegen = import ./headscale-codegen.nix { inherit pkgs self; };
  slurm-on-cephfs-job-roundtrip = import ./slurm-on-cephfs-job-roundtrip.nix { pkgs = cephPkgs; };
  slurm-on-cephfs-output-readable-from-other-compute =
    import ./slurm-on-cephfs-output-readable-from-other-compute.nix
      { pkgs = cephPkgs; };
  slurm-on-cephfs-concurrent-jobs-dont-interfere =
    import ./slurm-on-cephfs-concurrent-jobs-dont-interfere.nix
      { pkgs = cephPkgs; };
  slurm-ha-shared-queue-state = import ./slurm-ha-shared-queue-state.nix { inherit pkgs; };
  slurm-ha-failover-on-primary-death = import ./slurm-ha-failover-on-primary-death.nix {
    inherit pkgs;
  };
  slurm-ha-queue-survives-failover = import ./slurm-ha-queue-survives-failover.nix { inherit pkgs; };
  slurm-ha-backup-accepts-new-jobs-after-failover =
    import ./slurm-ha-backup-accepts-new-jobs-after-failover.nix
      { inherit pkgs; };
  slurm-ha-primary-returns-to-service = import ./slurm-ha-primary-returns-to-service.nix {
    inherit pkgs;
  };
  slurm-ha-running-jobs-continue-after-failover =
    import ./slurm-ha-running-jobs-continue-after-failover.nix
      { inherit pkgs; };
  kexec-bundle-smoke = import ./kexec-bundle-smoke.nix { inherit pkgs self; };
  private-cluster = import ./private-cluster.nix { inherit pkgs self; };
  shared-cluster = import ./shared-cluster.nix { inherit pkgs self; };
  cluster-isolation = import ./cluster-isolation.nix { inherit pkgs self; };
  bootstrap-tag = import ./bootstrap-tag.nix { inherit pkgs; };
  taildrive = import ./taildrive.nix { inherit pkgs; };
  harmonia = import ./harmonia.nix { inherit pkgs; };
  cephfs = import ./cephfs.nix {
    pkgs = cephPkgs;
    inherit self;
  };
  dev-fpga = import ./dev-fpga.nix { inherit pkgs self inputs; };
  unix-access-tiers = import ./unix-access-tiers.nix { inherit pkgs self inputs; };
  observability = import ./observability.nix { inherit pkgs self inputs; };
  analytics = import ./analytics.nix { inherit pkgs self inputs; };
  logs = import ./logs.nix { inherit pkgs self inputs; };
  alerts = import ./alerts.nix { inherit pkgs self inputs; };
  hardware-health = import ./hardware-health.nix { inherit pkgs self inputs; };
  slurm-metrics = import ./slurm-metrics.nix { inherit pkgs self inputs; };
  cephfs-replicated-read-cross-client = import ./cephfs-replicated-read-cross-client.nix {
    pkgs = cephPkgs;
  };
  cephfs-fsync-durability-across-graceful-shutdown =
    import ./cephfs-fsync-durability-across-graceful-shutdown.nix
      { pkgs = cephPkgs; };
  cephfs-fsync-durability-across-hard-crash = import ./cephfs-fsync-durability-across-hard-crash.nix {
    pkgs = cephPkgs;
  };
  cephfs-writes-available-with-one-storage-down =
    import ./cephfs-writes-available-with-one-storage-down.nix
      { pkgs = cephPkgs; };
  cephfs-blocks-writes-when-min-size-violated =
    import ./cephfs-blocks-writes-when-min-size-violated.nix
      { pkgs = cephPkgs; };
  cephfs-mon-rejoin-after-graceful-shutdown = import ./cephfs-mon-rejoin-after-graceful-shutdown.nix {
    pkgs = cephPkgs;
  };
  cephfs-mon-rejoin-after-hard-crash = import ./cephfs-mon-rejoin-after-hard-crash.nix {
    pkgs = cephPkgs;
  };
  cephfs-osd-rejoin-after-graceful-shutdown = import ./cephfs-osd-rejoin-after-graceful-shutdown.nix {
    pkgs = cephPkgs;
  };
  cephfs-osd-rejoin-after-hard-crash = import ./cephfs-osd-rejoin-after-hard-crash.nix {
    pkgs = cephPkgs;
  };
}
