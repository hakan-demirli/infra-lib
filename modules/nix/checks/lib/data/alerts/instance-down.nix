{
  groups = [
    {
      name = "instance_down";
      interval = "15s";
      rules = [
        {
          alert = "InstanceDown";
          expr = "up == 0";
          for = "30s";
          labels = {
            severity = "critical";
            category = "availability";
          };
        }
      ];
    }
  ];
}
