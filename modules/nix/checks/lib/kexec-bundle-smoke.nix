{ pkgs, self }:
let

  testRootKeys = [
    "ssh-ed25519 AAAA-test-root-A test-root@kexec-smoke-1"
    "ssh-ed25519 AAAA-test-root-B test-root@kexec-smoke-2"
  ];

  kexecSystem = self.inputs.nixpkgs.lib.nixosSystem {
    inherit (pkgs) system;
    specialArgs = {
      rootKeys = testRootKeys;
    };
    modules = [ (self + "/modules/ops/kexec.nix") ];
  };

  kexecBundle = kexecSystem.config.system.build.kexec_bundle;

  netbootInit = kexecSystem.config.system.build.netbootRamdisk;
in
pkgs.runCommand "kexec-bundle-smoke"
  {
    bundlePath = "${kexecBundle}";
    netbootInitPath = "${netbootInit}";
    expectedKey1 = builtins.elemAt testRootKeys 0;
    expectedKey2 = builtins.elemAt testRootKeys 1;
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }
    pass() { echo "PASS: $*"; }

    [ -e "$bundlePath" ] || fail "kexec bundle artifact does not exist: $bundlePath"
    pass "kexec bundle artifact exists at $bundlePath"

    [ -s "$bundlePath" ] || fail "kexec bundle artifact is empty"
    pass "kexec bundle artifact non-empty"

    head -c 4 "$bundlePath" | grep -q "#!" \
      || fail "kexec bundle does not start with shebang"
    pass "kexec bundle is a shell script (shebang present)"

    [ -d "$netbootInitPath" ] || fail "netbootRamdisk derivation not a dir"
    [ -f "$netbootInitPath/initrd" ] \
      || fail "netbootRamdisk missing /initrd file"
    pass "netbootRamdisk has /initrd"

    ${pkgs.binutils}/bin/strings "$bundlePath" | head -1000 > /tmp/strings.head

    grep -q kexec /tmp/strings.head \
      || fail "bundle does not mention kexec (suspicious; binary may be malformed)"
    pass "bundle references kexec"

    echo "KEXEC BUNDLE SMOKE VERIFIED"
    echo "    bundle: $bundlePath"
    echo "    size:   $(wc -c < $bundlePath) bytes"
    touch $out
  ''
