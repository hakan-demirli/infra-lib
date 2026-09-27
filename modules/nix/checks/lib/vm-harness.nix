final: prev:
let
  waitForSockets = final.writeShellApplication {
    name = "qemu-wait-for-sockets";
    text = ''
      qemu=$1
      shift
      deadline=$((SECONDS + 60))
      args=("$@")
      for ((i = 0; i + 1 < ''${#args[@]}; i++)); do
        [[ ''${args[i]} == -chardev ]] || continue
        spec=",''${args[i + 1]},"
        [[ $spec == ,socket,* && $spec == *,path=* ]] || continue
        [[ $spec == *,server=on,* || $spec == *,server,* ]] && continue
        path=''${spec#*,path=}
        path=''${path%%,*}
        while [[ ! -S $path ]] && ((SECONDS < deadline)); do
          sleep 0.1
        done
      done
      exec "$qemu" "$@"
    '';
  };

  qemu = final.symlinkJoin {
    name = "${prev.qemu_test.name}-socket-wait";
    paths = [ prev.qemu_test ];
    nativeBuildInputs = [ final.makeWrapper ];
    postBuild = ''
      for binary in "$out"/bin/qemu-system-*; do
        target=$(readlink -f "$binary")
        rm "$binary"
        makeWrapper ${final.lib.getExe waitForSockets} "$binary" --add-flags "$target"
      done
    '';
  };
in
{
  nixos-test-driver = final.lib.makeOverridable (
    args:
    (prev.nixos-test-driver.override args).overridePythonAttrs (old: {
      patches = (old.patches or [ ]) ++ [ ./vm-harness-qmp.patch ];
    })
  ) { };

  testers = prev.testers // {
    runNixOSTest =
      test:
      prev.testers.runNixOSTest {
        imports = [ test ];
        qemu.package = qemu;
      };
  };
}
