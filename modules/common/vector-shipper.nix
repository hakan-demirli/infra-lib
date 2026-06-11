{
  lib,
  host,
  cluster,
  ...
}:
let
  inherit (lib)
    attrValues
    elem
    filter
    head
    mkIf
    ;

  obsHosts = filter (h: elem "mgmt-observability" (h.roles or [ ])) (
    attrValues (cluster.hosts or { })
  );
  obsTarget = if obsHosts == [ ] then null else (head obsHosts).id;

  enabled = (obsTarget != null) && (host.monitoring.enabled or true) && (host.id != obsTarget);
in
{
  config = mkIf enabled {
    services.vector = {
      enable = true;
      journaldAccess = true;
      settings = {
        sources.journald = {
          type = "journald";
          current_boot_only = true;
        };

        transforms.label = {
          type = "remap";
          inputs = [ "journald" ];
          source = ''
            .host = "${host.id}"
            .unit = del(._SYSTEMD_UNIT)
            if .unit == null { .unit = "unknown" }
            .priority = del(.PRIORITY)
            if .priority == null { .priority = "info" }
          '';
        };

        sinks.victorialogs = {
          type = "http";
          inputs = [ "label" ];
          uri = "http://${obsTarget}:9428/insert/jsonline?_stream_fields=host,unit&_msg_field=message&_time_field=timestamp";
          method = "post";
          encoding = {
            codec = "json";
          };
          framing = {
            method = "newline_delimited";
          };
          batch = {
            max_events = 200;
            timeout_secs = 5;
          };
          request = {
            timeout_secs = 10;
            retry_attempts = 5;
            retry_initial_backoff_secs = 1;
            retry_max_duration_secs = 60;
          };
        };
      };
    };
  };
}
