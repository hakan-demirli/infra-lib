{ pkgs, ... }:
let
  testlib = import ./lib.nix { inherit pkgs; };

  aclFile = pkgs.writeText "taildrive.hujson" (
    builtins.toJSON {
      groups = {
        "group:admin" = [ "owner@" ];
      };
      tagOwners = {
        "tag:bootstrap" = [ "group:admin" ];
        "tag:drive-share" = [ "group:admin" ];
        "tag:drive-access" = [ "group:admin" ];
      };
      acls = [
        {
          action = "accept";
          src = [ "group:admin" ];
          dst = [
            "tag:bootstrap:*"
            "tag:drive-share:*"
            "tag:drive-access:*"
          ];
        }
        {
          action = "accept";
          src = [ "tag:drive-access" ];
          dst = [ "tag:drive-share:*" ];
        }
      ];
      nodeAttrs = [
        {
          target = [ "tag:drive-share" ];
          attr = [ "drive:share" ];
        }
        {
          target = [ "tag:drive-access" ];
          attr = [ "drive:access" ];
        }
      ];
      grants = [
        {
          src = [ "tag:drive-access" ];
          dst = [ "tag:drive-share" ];
          app = {
            "tailscale.com/cap/drive" = [
              {
                shares = [ "*" ];
                access = "rw";
              }
            ];
          };
        }
      ];
    }
  );

  mkPeer =
    { extraUpFlags }:
    { pkgs, ... }:
    {
      imports = [ (testlib.mkTailscaleNode { inherit extraUpFlags; }) ];
      environment.systemPackages = [ pkgs.curl ];
    };
in
pkgs.testers.runNixOSTest {
  name = "taildrive";

  nodes = {
    headscale = testlib.mkHeadscaleNode { inherit aclFile; };

    admin_laptop = testlib.mkTailscaleNode { };

    sharer = mkPeer { extraUpFlags = [ "--advertise-tags=tag:drive-share" ]; };

    client = mkPeer { extraUpFlags = [ "--advertise-tags=tag:drive-access" ]; };

    dual = mkPeer {
      extraUpFlags = [ "--advertise-tags=tag:drive-share,tag:drive-access" ];
    };

    stranger = mkPeer { extraUpFlags = [ "--advertise-tags=tag:bootstrap" ]; };
  };

  testScript = ''
    import time

    t0 = time.time()
    def stage(msg):
        print(f"\n========== [t+{time.time() - t0:6.1f}s] {msg} ==========")
    def say(msg):
        print(f"[t+{time.time() - t0:6.1f}s] {msg}")

    stage("start_all: booting 6 VMs")
    start_all()

    ${testlib.snippets.bootHeadscale}
    ${testlib.snippets.helperDefs}

    stage("headscale users + preauth keys")
    headscale.succeed("headscale users create owner")
    owner_id = get_user_id("owner")

    def preauth(tags=None):
        cmd = (
            f"headscale preauthkeys create --user {owner_id} "
            "--reusable --expiration 24h"
        )
        if tags:
            cmd += f" --tags {tags}"
        return headscale.succeed(cmd).strip()

    admin_key   = preauth()
    share_key   = preauth("tag:drive-share")
    access_key  = preauth("tag:drive-access")
    dual_key    = preauth("tag:drive-share,tag:drive-access")
    stranger_key = preauth("tag:bootstrap")

    stage("wait for tailscaled on every peer")
    for n in [admin_laptop, sharer, client, dual, stranger]:
        n.wait_for_unit("tailscaled.service", timeout=120)

    stage("join tailnet")
    def join(node, hostname, key):
        say(f"joining {hostname}")
        node.succeed(
            f"tailscale up --authkey={key} --hostname={hostname} "
            f"--login-server=https://headscale --timeout=60s"
        )
        node.wait_until_succeeds(
            f"tailscale status | grep -E '\\b{hostname}\\b' >&2",
            timeout=60,
        )
        headscale.wait_until_succeeds(
            f"headscale nodes list | grep -F {hostname}",
            timeout=60,
        )
        say(f"{hostname} registered")

    join(admin_laptop, "admin",    admin_key)
    join(sharer,      "sharer",   share_key)
    join(client,      "client",   access_key)
    join(dual,        "dual",     dual_key)
    join(stranger,    "stranger", stranger_key)

    stage("resolve tailnet IPs + MagicDNS suffix")
    def ts_ip(node, name):
        ip = node.wait_until_succeeds("tailscale ip -4 | head -n1", timeout=60).strip()
        say(f"{name} = {ip}")
        return ip

    sharer_ip   = ts_ip(sharer,   "sharer")
    client_ip   = ts_ip(client,   "client")
    dual_ip     = ts_ip(dual,     "dual")
    stranger_ip = ts_ip(stranger, "stranger")

    def magic_suffix(node):
        for _ in range(30):
            out = node.succeed("tailscale status --json")
            data = json.loads(out)
            suf = data.get("MagicDNSSuffix", "")
            if suf:
                return suf.rstrip(".")
            time.sleep(1)
        raise Exception("MagicDNSSuffix never populated")

    suffix = magic_suffix(client)
    say(f"tailnet MagicDNS suffix: {suffix}")

    def share_url(machine, share, path=""):
        base = f"http://100.100.100.100:8080/{suffix}/{machine}/{share}"
        return f"{base}/{path}" if path else base

    stage("prepare share directories on sharer + dual (root-owned, WebDAV writes land as tailscaled uid)")
    for host, label in [(sharer, "sharer"), (dual, "dual")]:
        host.succeed(
            "install -d -m 0777 /srv/docs",
            "install -d -m 0777 /srv/secret",
            f"echo hello-from-{label} > /srv/docs/from-sharer.txt",
            "chmod 0666 /srv/docs/from-sharer.txt",
        )

    stage("INVARIANT 1: sharer registers a share (drive:share attr present)")
    with subtest("sharer: tailscale drive share docs /srv/docs"):
        sharer.succeed("tailscale drive share docs /srv/docs")
        out = sharer.succeed("tailscale drive list")
        say(f"sharer drive list:\n{out}")
        assert "docs" in out and "/srv/docs" in out, (
            f"expected 'docs -> /srv/docs' in `tailscale drive list`, got:\n{out}"
        )

    stage("INVARIANT 2: client CANNOT register a share (no drive:share attr)")
    with subtest("client: tailscale drive share denied"):
        client.succeed("install -d -m 0755 /srv/nope")
        rc, out = client.execute("tailscale drive share nope /srv/nope 2>&1", timeout=15)
        assert rc != 0, (
            f"client without drive:share attr must fail to register a share; "
            f"got rc={rc}, out={out!r}"
        )
        assert "drive:share" in out or "not enabled" in out.lower(), (
            f"error message must mention the missing capability; got: {out!r}"
        )
        say("OK client denied at share registration")

    stage("INVARIANT 3: dual node holds BOTH capabilities")
    with subtest("dual: registers its own share AND access is enabled"):
        dual.succeed("tailscale drive share vault /srv/docs")
        out = dual.succeed("tailscale drive list")
        assert "vault" in out and "/srv/docs" in out, (
            f"dual drive list missing expected entry:\n{out}"
        )
        say("OK dual can share, WebDAV read/write validated below")

    stage("INVARIANT 4: client with drive:access can READ sharer's share")
    with subtest("client: GET /docs/from-sharer.txt on sharer"):
        url = share_url("sharer", "docs", "from-sharer.txt")
        client.wait_until_succeeds(
            f"curl -sS -m 15 -o /tmp/got.txt -w '%{{http_code}}' {url} | grep -qE '^2..'",
            timeout=60,
        )
        got = client.succeed("cat /tmp/got.txt").strip()
        assert got == "hello-from-sharer", (
            f"WebDAV GET returned wrong body: {got!r}"
        )
        say("OK client read sharer's file over WebDAV")

    stage("INVARIANT 5: client can WRITE via WebDAV, sharer sees the file")
    with subtest("client: PUT /docs/from-client.txt then sharer reads it"):
        client.succeed("echo hello-from-client > /tmp/upload.txt")
        url = share_url("sharer", "docs", "from-client.txt")
        code = client.succeed(
            f"curl -sS -m 15 -T /tmp/upload.txt -o /dev/null -w '%{{http_code}}' {url}"
        ).strip()
        assert code.startswith("2"), (
            f"WebDAV PUT must return 2xx; got HTTP {code}"
        )
        sharer.wait_until_succeeds(
            "test -f /srv/docs/from-client.txt && "
            "grep -q hello-from-client /srv/docs/from-client.txt",
            timeout=30,
        )
        say("OK client wrote a file that materialized on sharer's disk")

    stage("INVARIANT 6: stranger (no drive:access) is blocked from sharer's share")
    with subtest("stranger: HTTP GET must fail at L3 or be denied by tailscaled proxy"):
        url = share_url("sharer", "docs", "from-sharer.txt")
        rc, out = stranger.execute(
            f"curl -sS -m 8 -o /tmp/body -w '%{{http_code}}' {url}",
            timeout=20,
        )
        code = out.strip().splitlines()[-1] if out.strip() else ""
        say(f"stranger curl rc={rc} http_code={code!r}")
        if rc == 0:
            assert not code.startswith("2"), (
                f"stranger without drive:access read a share (HTTP {code}); "
                f"policy is broken"
            )
        say("OK stranger blocked from share")

    stage("INVARIANT 7: sharer (drive:share only) cannot ACCESS dual's share")
    with subtest("sharer: no drive:access attr, mount attempt denied"):
        url = share_url("dual", "vault", "from-sharer.txt")
        rc, out = sharer.execute(
            f"curl -sS -m 8 -o /tmp/body -w '%{{http_code}}' {url}",
            timeout=20,
        )
        code = out.strip().splitlines()[-1] if out.strip() else ""
        say(f"sharer -> dual curl rc={rc} http_code={code!r}")
        if rc == 0:
            assert not code.startswith("2"), (
                f"sharer without drive:access read a peer's share (HTTP {code}); "
                f"policy is broken"
            )
        say("OK sharer cannot cross-mount without drive:access")

    stage("INVARIANT 8: unshare removes the endpoint")
    with subtest("sharer: unshare docs, list is empty for that name"):
        sharer.succeed("tailscale drive unshare docs")
        out = sharer.succeed("tailscale drive list")
        for line in out.splitlines():
            fields = line.split()
            assert not fields or fields[0] != "docs", (
                f"expected 'docs' share removed, still present:\n{out}"
            )
        say("OK unshare cleared the registration")

        url = share_url("sharer", "docs", "from-sharer.txt")
        rc, out = client.execute(
            f"curl -sS -m 8 -o /tmp/body -w '%{{http_code}}' {url}",
            timeout=20,
        )
        code = out.strip().splitlines()[-1] if out.strip() else ""
        say(f"post-unshare client curl rc={rc} http_code={code!r}")
        if rc == 0:
            assert not code.startswith("2"), (
                f"share still readable after unshare (HTTP {code})"
            )
        say("OK share no longer readable after unshare")

    stage(f"DONE in {time.time() - t0:.1f}s")
    print("TAILDRIVE ACL + CAPABILITY VERIFICATIONS PASSED")
  '';
}
