{
  pkgs,
  self,
  inputs,
  ...
}:
let
  inherit (pkgs) lib;
  vmImpermanence = import ./lib/vm-impermanence.nix { inherit inputs; };

  captureServer = pkgs.writeText "notification-capture.py" ''
    import http.server
    import json
    import pathlib
    import socketserver
    import threading

    output_dir = pathlib.Path("/var/lib/notification-capture")
    output_dir.mkdir(parents=True, exist_ok=True)
    lock = threading.Lock()

    def record(name, payload):
        with lock:
            with (output_dir / name).open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(payload) + "\n")

    class HTTPHandler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length).decode("utf-8")
            port = self.server.server_address[1]
            record(
                f"http-{port}.jsonl",
                {
                    "path": self.path,
                    "headers": dict(self.headers.items()),
                    "body": body,
                },
            )

            if port == 9997:
                response = b'{"ok":true,"result":{"message_id":1,"chat":{"id":123}}}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)
            elif port == 9998:
                self.send_response(204)
                self.end_headers()
            else:
                self.send_response(200)
                self.end_headers()

        def log_message(self, *_):
            pass

    class SMTPHandler(socketserver.StreamRequestHandler):
        def handle(self):
            self.wfile.write(b"220 capture ESMTP\r\n")
            data = None
            while True:
                line = self.rfile.readline()
                if not line:
                    return

                if data is not None:
                    if line == b".\r\n":
                        record("smtp.jsonl", {"body": b"".join(data).decode("utf-8")})
                        data = None
                        self.wfile.write(b"250 queued\r\n")
                    else:
                        data.append(line)
                    continue

                command = line.decode("utf-8").strip().upper()
                if command.startswith(("EHLO", "HELO")):
                    self.wfile.write(b"250-capture\r\n250 HELP\r\n")
                elif command.startswith(("MAIL FROM", "RCPT TO")):
                    self.wfile.write(b"250 ok\r\n")
                elif command == "DATA":
                    data = []
                    self.wfile.write(b"354 end with <CRLF>.<CRLF>\r\n")
                elif command == "QUIT":
                    self.wfile.write(b"221 bye\r\n")
                    return
                else:
                    self.wfile.write(b"250 ok\r\n")

    class ThreadingHTTPServer(http.server.ThreadingHTTPServer):
        allow_reuse_address = True

    class ThreadingTCPServer(socketserver.ThreadingTCPServer):
        allow_reuse_address = True

    servers = [
        ThreadingHTTPServer(("127.0.0.1", port), HTTPHandler)
        for port in (9997, 9998, 9999)
    ]
    servers.append(ThreadingTCPServer(("127.0.0.1", 1025), SMTPHandler))

    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()

    threading.Event().wait()
  '';
in
pkgs.testers.runNixOSTest {
  name = "alertmanager-notifications";

  nodes.notifications =
    { ... }:
    {
      imports = [
        vmImpermanence
        ../../../services/alertmanager.nix
      ];
      _module.args = {
        inherit self;
        host.id = "notifications";
      };

      services.cluster-alertmanager = {
        groupWait = "1s";
        groupInterval = "2s";
        repeatInterval = "1h";
        channels = {
          ntfy = {
            baseUrl = "http://127.0.0.1:9999";
            topic = "alerts";
          };
          telegram = {
            enable = true;
            apiUrl = "http://127.0.0.1:9997";
          };
          discord = {
            enable = true;
          };
          email = {
            enable = true;
            smarthost = "127.0.0.1:1025";
            from = "alerts@example.test";
            to = "operator@example.test";
            requireTLS = false;
          };
        };
      };

      environment.etc = {
        "alertmanager-test/telegram-token".text = "test-token\n";
        "alertmanager-test/telegram-chat-id".text = "123\n";
        "alertmanager-test/discord-webhook-url".text = "http://127.0.0.1:9998/discord\n";
      };
      environment.systemPackages = [ pkgs.python3 ];

      systemd.tmpfiles.rules = [
        "d /run/secrets 0755 root root -"
        "L+ /run/secrets/alertmanager-telegram-bot-token - - - - /etc/alertmanager-test/telegram-token"
        "L+ /run/secrets/alertmanager-telegram-chat-id - - - - /etc/alertmanager-test/telegram-chat-id"
        "L+ /run/secrets/alertmanager-discord-webhook-url - - - - /etc/alertmanager-test/discord-webhook-url"
      ];

      systemd.services = {
        notification-capture = {
          wantedBy = [ "multi-user.target" ];
          before = [
            "alertmanager.service"
            "alertmanager-ntfy.service"
          ];
          serviceConfig = {
            ExecStart = "${pkgs.python3}/bin/python ${captureServer}";
            StateDirectory = "notification-capture";
          };
        };
        alertmanager = {
          requires = [ "notification-capture.service" ];
          after = [ "notification-capture.service" ];
        };
        alertmanager-ntfy = {
          requires = [ "notification-capture.service" ];
          after = [ "notification-capture.service" ];
        };
      };

      networking.firewall.enable = lib.mkForce false;
      virtualisation = {
        memorySize = 1024;
        cores = 2;
      };
    };

  testScript = ''
    import json
    import time

    capture_dir = "/var/lib/notification-capture"

    def read_events(name):
        output = notifications.succeed(f"cat {capture_dir}/{name}")
        return [json.loads(line) for line in output.splitlines() if line.strip()]

    def event_count(name):
        rc, output = notifications.execute(f"wc -l < {capture_dir}/{name}")
        return 0 if rc != 0 else int(output.strip())

    notifications.start()
    notifications.wait_for_unit("notification-capture.service")
    notifications.wait_for_unit("alertmanager-ntfy.service")
    notifications.wait_for_unit("alertmanager.service")
    notifications.wait_for_open_port(8000)
    notifications.wait_for_open_port(9093)
    for port in (1025, 9997, 9998, 9999):
        notifications.wait_for_open_port(port)

    notifications.fail("send-alert MissingSeverity --annotation=summary=test")
    notifications.fail("send-alert InvalidSeverity severity=none --annotation=summary=test")
    notifications.fail("send-alert severity=warning --annotation=summary=test")
    notifications.fail("send-alert AnnotationSeverity --annotation severity=critical")
    notifications.fail("send-alert Foo --date.format severity=critical")
    notifications.fail("send-alert severity=critical --output json")
    notifications.fail('send-alert "" severity=warning')
    notifications.fail("send-alert alertname= severity=warning")
    notifications.fail("send-alert alertname=~Probe severity=warning")

    notifications.succeed(
        "send-alert FanoutProbe severity=warning instance=test-host "
        "--annotation=summary='Fan-out test' "
        "--annotation=description='All configured channels receive this alert.' "
        "--generator-url=http://example.test/alerts/FanoutProbe"
    )

    for name in ("http-9997.jsonl", "http-9998.jsonl", "http-9999.jsonl", "smtp.jsonl"):
        notifications.wait_until_succeeds(f"test -s {capture_dir}/{name}", timeout=60)

    telegram = read_events("http-9997.jsonl")[-1]
    telegram_payload = json.loads(telegram["body"])
    assert telegram["path"] == "/bottest-token/sendMessage", telegram
    assert telegram_payload["chat_id"] == "123", telegram_payload
    assert "FIRING: Fan-out test" in telegram_payload["text"], telegram_payload

    discord = json.loads(read_events("http-9998.jsonl")[-1]["body"])
    assert discord["username"] == "Alertmanager", discord
    assert "[FIRING:1] FanoutProbe (warning)" in discord["embeds"][0]["title"], discord
    assert "FIRING: Fan-out test" in discord["embeds"][0]["description"], discord

    ntfy = read_events("http-9999.jsonl")[-1]
    ntfy_headers = {key.lower(): value for key, value in ntfy["headers"].items()}
    assert ntfy["path"] == "/alerts", ntfy
    assert ntfy_headers["x-priority"] == "high", ntfy_headers
    assert "warning" in ntfy_headers["x-tags"], ntfy_headers
    assert ntfy_headers["x-title"] == "[FIRING] Fan-out test", ntfy_headers
    assert "All configured channels receive this alert." in ntfy["body"], ntfy

    email = read_events("smtp.jsonl")[-1]["body"]
    assert "Subject: [FIRING:1] FanoutProbe (warning)" in email, email
    assert "FIRING: Fan-out test" in email, email

    firing_counts = {
        name: event_count(name)
        for name in ("http-9997.jsonl", "http-9998.jsonl", "http-9999.jsonl", "smtp.jsonl")
    }

    notifications.succeed(
        "end=$(date -u +%Y-%m-%dT%H:%M:%SZ); "
        "send-alert FanoutProbe severity=warning instance=test-host "
        "--annotation=summary='Fan-out test' "
        "--annotation=description='All configured channels receive this alert.' "
        "--generator-url=http://example.test/alerts/FanoutProbe "
        "--end=\"$end\""
    )

    for name, count in firing_counts.items():
        notifications.wait_until_succeeds(
            f"test $(wc -l < {capture_dir}/{name}) -gt {count}", timeout=60
        )

    assert "RESOLVED: Fan-out test" in json.loads(
        read_events("http-9997.jsonl")[-1]["body"]
    )["text"]
    assert "[RESOLVED] FanoutProbe (warning)" in json.loads(
        read_events("http-9998.jsonl")[-1]["body"]
    )["embeds"][0]["title"]
    assert read_events("http-9999.jsonl")[-1]["headers"]["X-Priority"] == "default"
    assert "Subject: [RESOLVED] FanoutProbe (warning)" in read_events("smtp.jsonl")[-1]["body"]

    resolved_counts = {
        name: event_count(name)
        for name in ("http-9997.jsonl", "http-9998.jsonl", "http-9999.jsonl", "smtp.jsonl")
    }
    notifications.succeed(
        "curl -fsS -H 'Content-Type: application/json' "
        "--data '[{\"labels\":{\"alertname\":\"Watchdog\",\"severity\":\"none\"},"
        "\"annotations\":{\"summary\":\"dead-man switch\"}}]' "
        "http://127.0.0.1:9093/api/v2/alerts"
    )
    time.sleep(5)
    for name, count in resolved_counts.items():
        assert event_count(name) == count, (
            f"severity=none escaped through {name}: before={count}, after={event_count(name)}"
        )
  '';
}
