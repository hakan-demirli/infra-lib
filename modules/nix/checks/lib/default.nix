{
  pkgs,
  self,
  inputs,
  ...
}:
{
  inventory-validation = import ./inventory-validation.nix { inherit pkgs self; };
  role-secrets = import ./role-secrets.nix { inherit pkgs self; };
  disko-wiring = import ./disko-wiring.nix { inherit pkgs self; };
  lib-multiroot = import ./lib-multiroot.nix { inherit pkgs self; };
  cluster-fs-modules-smoke = import ./cluster-fs-modules-smoke.nix { inherit pkgs self; };
  mkrole-determinism = import ./mkrole-determinism.nix { inherit pkgs self; };
  ssh-key-rotation = import ./ssh-key-rotation.nix { inherit pkgs self; };
  user-offboarding = import ./user-offboarding.nix { inherit pkgs self; };
  virt-host-smoke = import ./virt-host-smoke.nix { inherit pkgs self; };
  headscale-ha-shared-state-via-postgres = import ./headscale-ha-shared-state-via-postgres.nix {
    inherit pkgs;
  };
  slurm-on-cephfs-job-roundtrip = import ./slurm-on-cephfs-job-roundtrip.nix { inherit pkgs; };
  slurm-on-cephfs-output-readable-from-other-compute =
    import ./slurm-on-cephfs-output-readable-from-other-compute.nix
      { inherit pkgs; };
  slurm-on-cephfs-concurrent-jobs-dont-interfere =
    import ./slurm-on-cephfs-concurrent-jobs-dont-interfere.nix
      { inherit pkgs; };
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
  cephfs = import ./cephfs.nix { inherit pkgs self; };
  dev-fpga = import ./dev-fpga.nix { inherit pkgs self inputs; };
  access-tiers = import ./access-tiers.nix { inherit pkgs self inputs; };
  observability = import ./observability.nix { inherit pkgs self inputs; };
  analytics = import ./analytics.nix { inherit pkgs self inputs; };
  logs = import ./logs.nix { inherit pkgs self inputs; };
  alerts = import ./alerts.nix { inherit pkgs self inputs; };
  hardware-health = import ./hardware-health.nix { inherit pkgs self inputs; };
  slurm-metrics = import ./slurm-metrics.nix { inherit pkgs self inputs; };
  cephfs-replicated-read-cross-client = import ./cephfs-replicated-read-cross-client.nix {
    inherit pkgs;
  };
  cephfs-fsync-durability-across-graceful-shutdown =
    import ./cephfs-fsync-durability-across-graceful-shutdown.nix
      { inherit pkgs; };
  cephfs-fsync-durability-across-hard-crash = import ./cephfs-fsync-durability-across-hard-crash.nix {
    inherit pkgs;
  };
  cephfs-writes-available-with-one-storage-down =
    import ./cephfs-writes-available-with-one-storage-down.nix
      { inherit pkgs; };
  cephfs-blocks-writes-when-min-size-violated =
    import ./cephfs-blocks-writes-when-min-size-violated.nix
      { inherit pkgs; };
  cephfs-mon-rejoin-after-graceful-shutdown = import ./cephfs-mon-rejoin-after-graceful-shutdown.nix {
    inherit pkgs;
  };
  cephfs-mon-rejoin-after-hard-crash = import ./cephfs-mon-rejoin-after-hard-crash.nix {
    inherit pkgs;
  };
  cephfs-osd-rejoin-after-graceful-shutdown = import ./cephfs-osd-rejoin-after-graceful-shutdown.nix {
    inherit pkgs;
  };
  cephfs-osd-rejoin-after-hard-crash = import ./cephfs-osd-rejoin-after-hard-crash.nix {
    inherit pkgs;
  };
}
