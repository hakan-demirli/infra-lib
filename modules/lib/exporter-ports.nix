let
  slurmPorts = import ./slurm-ports.nix;
in
{
  node = 9100;
  smartctl = 9633;
  ipmi = 9290;
  "lm-sensors" = 9100;
  ceph = 9128;
  slurm = slurmPorts.controller;
  zfs = 9134;
}
