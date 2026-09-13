{ pkgs }:
pkgs.runCommand "ci-workflows"
  {
    src = pkgs.lib.fileset.toSource {
      root = ../../../..;
      fileset = ../../../../.github/workflows;
    };
    nativeBuildInputs = [
      (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
      pkgs.jq
    ];
  }
  ''
    python3 - <<'PY'
    import json
    import os
    import pathlib
    import subprocess
    import tempfile
    import yaml

    root = pathlib.Path(os.environ["src"]) / ".github/workflows"
    external = yaml.safe_load((root / "external-builds.yml").read_text())
    checks = yaml.safe_load((root / "checks.yml").read_text())
    discovery = external["jobs"]["discover"]["steps"][-1]["run"]
    external_gate = external["jobs"]["required-result"]["steps"][0]["run"]
    checks_gate = checks["jobs"]["required-result"]["steps"][0]["run"]

    def run(script, **env):
        return subprocess.run(
            ["${pkgs.runtimeShell}", "-euo", "pipefail", "-c", script],
            env=os.environ | env, capture_output=True, text=True,
        )

    with tempfile.TemporaryDirectory() as directory:
        work = pathlib.Path(directory)
        for name, script in {
            "git": "exit 0",
            "nix": 'test "$EVAL_FAIL" = false || exit 1\ncase "$CI_FLAKE" in *ci-base*) printf "%s" "$PREVIOUS";; *) printf "%s" "$CURRENT";; esac',
        }.items():
            executable = work / name
            executable.write_text("#!${pkgs.runtimeShell}\n" + script + "\n")
            executable.chmod(0o755)

        original = {"name": "example", "system": "x86_64-linux", "drvPath": "/nix/store/old.drv"}
        changed = original | {"drvPath": "/nix/store/new.drv"}
        added = original | {"name": "another"}
        cases = [
            ([original], [original], [], "base", False),
            ([changed], [original], [changed], "base", False),
            ([original, added], [original], [added], "base", False),
            ([], [original], [], "base", False),
            ([original], [], [original], "base", False),
            ([original], [original], [original], "", False),
            ([original], [original], [], "base", True),
        ]
        for current, previous, expected, base, fail in cases:
            output = work / "output"
            output.write_text("")
            result = run(
                discovery, CURRENT=json.dumps(current), PREVIOUS=json.dumps(previous),
                BASE_SHA=base, EVAL_FAIL=str(fail).lower(), RUNNER_TEMP=directory,
                GITHUB_OUTPUT=str(output), PATH=directory + ":" + os.environ["PATH"],
            )
            if fail:
                assert result.returncode != 0
                continue
            assert result.returncode == 0, result.stderr
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
            assert json.loads(values["value"])["include"] == expected
            assert values["changed"] == str(bool(expected)).lower()

    for state in ["success", "failure", "cancelled", "skipped"]:
        result = run(checks_gate, RESULTS=json.dumps({
            "discover": {"result": "success"}, "build": {"result": state},
        }))
        assert (result.returncode == 0) == (state == "success")
        result = run(external_gate, DISCOVERY="success", CHANGED="true", BUILD=state)
        assert (result.returncode == 0) == (state == "success")
    assert run(checks_gate, RESULTS="{}").returncode != 0
    assert run(external_gate, DISCOVERY="failure", CHANGED="false", BUILD="skipped").returncode != 0
    assert run(external_gate, DISCOVERY="success", CHANGED="false", BUILD="skipped").returncode == 0
    assert run(external_gate, DISCOVERY="success", CHANGED="", BUILD="skipped").returncode != 0
    PY
    touch "$out"
  ''
