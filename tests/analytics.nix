{
  pkgs,
  ...
}:
let
  inherit (pkgs) lib;

  testCluster = {
    hosts = {
      analytics = {
        id = "analytics";
        state = "provisioned";
        monitoring = {
          enabled = true;
          exporters = [ "node" ];
          scrape_targets = [ ];
        };
      };
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "analytics";

  nodes.analytics =
    { ... }:
    {
      imports = [
        ../modules/common/node-exporter.nix
        ../modules/services/victoriametrics.nix
      ];

      _module.args = {
        host = {
          id = "analytics";
          monitoring = {
            enabled = true;
            exporters = [ "node" ];
            scrape_targets = [ ];
          };
        };
        cluster = testCluster;
      };

      networking.firewall.enable = lib.mkForce false;
      networking.extraHosts = "127.0.0.1 analytics";

      environment.systemPackages = with pkgs; [
        duckdb
        jq
      ];

      virtualisation = {
        memorySize = 1536;
        cores = 2;
      };
    };

  testScript = ''
    import time
    import json

    t0 = time.time()
    def stage(msg):
        print(f"\n========== [t+{time.time() - t0:6.1f}s] {msg} ==========")
    def say(msg):
        print(f"[t+{time.time() - t0:6.1f}s] {msg}")

    stage("boot")
    start_all()
    analytics.wait_for_unit("multi-user.target", timeout=120)
    analytics.wait_for_unit("victoriametrics.service", timeout=120)
    analytics.wait_for_open_port(9100, timeout=60)
    analytics.wait_for_open_port(8428, timeout=60)
    say("VM and node_exporter ready")

    stage("INVARIANT 1: accumulate >= 3 samples of node_load1")
    deadline = time.time() + 180
    samples = 0
    while time.time() < deadline:
        out = analytics.succeed(
            "curl -fsS -G "
            "--data-urlencode 'query=count_over_time(node_load1[5m])' "
            "http://127.0.0.1:8428/api/v1/query"
        )
        doc = json.loads(out)
        if doc.get("data", {}).get("result"):
            samples = int(float(doc["data"]["result"][0]["value"][1]))
            if samples >= 3:
                break
        time.sleep(5)
    assert samples >= 3, f"FAIL: only {samples} samples of node_load1 after 180s"
    say(f"VictoriaMetrics has {samples} samples")

    stage("INVARIANT 2: JSON-Lines export non-empty")
    analytics.succeed(
        "curl -fsS 'http://127.0.0.1:8428/api/v1/export?match%5B%5D="
        "node_load1%7Bjob%3D%22fleet-node%22%7D' > /tmp/load1.jsonl"
    )
    line_count = int(analytics.succeed("wc -l < /tmp/load1.jsonl").strip())
    file_size = int(analytics.succeed("stat -c %s /tmp/load1.jsonl").strip())
    say(f"export: {line_count} lines, {file_size} bytes")
    assert line_count >= 1, "FAIL: export returned zero series"
    sample_line = analytics.succeed("head -1 /tmp/load1.jsonl").strip()
    sample = json.loads(sample_line)
    assert sample["metric"]["__name__"] == "node_load1", f"FAIL: unexpected metric: {sample!r}"
    assert sample["values"], "FAIL: empty values array"
    assert sample["timestamps"], "FAIL: empty timestamps array"
    say(f"first series has {len(sample['values'])} values")

    stage("INVARIANT 3: DuckDB ingests JSON-Lines, mean + count match VM")
    sql_aggregate = """
      SELECT
        count(*)                    AS n_points,
        avg(v)                      AS mean_load,
        min(v)                      AS min_load,
        max(v)                      AS max_load
      FROM (
        SELECT unnest(values) AS v
        FROM read_json_auto('/tmp/load1.jsonl', format='newline_delimited')
      );
    """
    duck_out = analytics.succeed(
        f"duckdb -json -c \"{sql_aggregate}\""
    )
    say(f"duckdb aggregate: {duck_out.strip()}")
    duck_rows = json.loads(duck_out)
    assert duck_rows, "FAIL: duckdb returned no rows"
    row = duck_rows[0]
    assert row["n_points"] >= 3, f"FAIL: duckdb saw < 3 points: {row}"
    assert row["mean_load"] >= 0, f"FAIL: negative mean load: {row}"
    assert row["max_load"] < 100, f"FAIL: implausible max load: {row}"
    say(f"DuckDB: {row['n_points']} points, mean={row['mean_load']:.4f}, range=[{row['min_load']}, {row['max_load']}]")

    stage("INVARIANT 4: Parquet round-trip identical to source")
    analytics.succeed(
        "duckdb -c \""
        "COPY ("
        "  SELECT metric, unnest(values) AS load, unnest(timestamps) AS ts "
        "  FROM read_json_auto('/tmp/load1.jsonl', format='newline_delimited')"
        ") TO '/tmp/load1.parquet' (FORMAT PARQUET, COMPRESSION SNAPPY);"
        "\""
    )
    pq_size = int(analytics.succeed("stat -c %s /tmp/load1.parquet").strip())
    say(f"parquet size: {pq_size} bytes (vs jsonl {file_size} bytes)")
    assert pq_size > 0, "FAIL: parquet write produced empty file"

    sql_rt = """
      SELECT count(*) AS n, avg(load) AS mean
      FROM read_parquet('/tmp/load1.parquet');
    """
    pq_out = analytics.succeed(f"duckdb -json -c \"{sql_rt}\"")
    pq_row = json.loads(pq_out)[0]
    say(f"parquet readback: {pq_row}")
    assert pq_row["n"] == row["n_points"], (
        f"FAIL: parquet roundtrip cardinality mismatch: "
        f"jsonl {row['n_points']} vs parquet {pq_row['n']}"
    )
    assert abs(float(pq_row["mean"]) - float(row["mean_load"])) < 1e-6, (
        f"FAIL: parquet roundtrip mean drift: {pq_row['mean']} vs {row['mean_load']}"
    )

    stage("INVARIANT 5: per-minute bucket aggregation runs cleanly")
    sql_bucket = """
      SELECT
        date_trunc('minute', to_timestamp(ts / 1000)) AS bucket,
        avg(load) AS mean_load,
        count(*) AS n_samples
      FROM read_parquet('/tmp/load1.parquet')
      GROUP BY bucket
      ORDER BY bucket;
    """
    bucket_out = analytics.succeed(f"duckdb -json -c \"{sql_bucket}\"")
    buckets = json.loads(bucket_out)
    say(f"per-minute buckets: {len(buckets)} rows")
    for b in buckets[:5]:
        say(f"  {b}")
    assert buckets, "FAIL: per-minute aggregation returned empty"
    for b in buckets:
        assert b["mean_load"] >= 0, f"FAIL: negative bucket mean: {b}"
        assert b["n_samples"] >= 1, f"FAIL: empty bucket: {b}"

    stage(f"DONE in {time.time() - t0:.1f}s")
    print("ANALYTICS VERIFICATIONS PASSED")
  '';
}
