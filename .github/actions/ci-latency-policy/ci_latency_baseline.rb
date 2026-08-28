# frozen_string_literal: true

require "time"

module CiLatencyBaseline
  GENERATOR = "ci-latency-baseline-v2"
  HEADROOM_PERCENT = 10
  HEADROOM_FLOOR_MS = 60_000

  class Invalid < StandardError; end

  module_function

  def percentile(values, fraction)
    raise Invalid, "baseline requires at least one sample" if values.empty?

    sorted = values.sort
    rank = (fraction * sorted.length).ceil
    sorted[[rank - 1, 0].max]
  end

  def regression_limit(value)
    relative = (value * (100 + HEADROOM_PERCENT) + 99) / 100
    [relative, value + HEADROOM_FLOOR_MS].max
  end

  def normalized_runs(policy, runs)
    raise Invalid, "observed_baseline.runs must be a list" unless runs.is_a?(Array)

    slo = policy.fetch("slo")
    window = slo.fetch("window_samples")
    minimum = slo.fetch("min_samples")
    raise Invalid, "slo.window_samples must be positive" unless window.is_a?(Integer) && window.positive?
    raise Invalid, "slo.min_samples must be positive" unless minimum.is_a?(Integer) && minimum.positive?
    unless runs.all? { |run| run.is_a?(Hash) }
      raise Invalid, "observed_baseline runs must be objects"
    end

    selected = runs.sort_by do |run|
      started_at = parse_time(run, "started_at")
      id = positive_integer(run, "id")
      [started_at, id]
    end.reverse.first(window)
    if selected.length < minimum
      raise Invalid, "observed_baseline has #{selected.length} sample(s); policy requires #{minimum}"
    end

    topology_epoch = Time.iso8601(policy.fetch("topology_epoch"))
    ids = {}
    selected.map do |run|
      id = positive_integer(run, "id")
      raise Invalid, "observed_baseline contains duplicate run id #{id}" if ids[id]

      ids[id] = true
      wall_ms = positive_integer(run, "wall_ms")
      event = run.fetch("event")
      conclusion = run.fetch("conclusion")
      started_at = parse_time(run, "started_at")
      completed_at = parse_time(run, "completed_at")
      head_sha = run.fetch("head_sha")
      raise Invalid, "baseline run #{id} does not match policy event" unless event == policy.fetch("event")
      unless %w[success failure].include?(conclusion)
        raise Invalid, "baseline run #{id} is not a qualifying completed run"
      end
      raise Invalid, "baseline run #{id} predates topology_epoch" if started_at < topology_epoch
      raise Invalid, "baseline run #{id} completed before it started" unless completed_at > started_at
      unless head_sha.is_a?(String) && head_sha.match?(/\A[0-9a-f]{40}\z/)
        raise Invalid, "baseline run #{id} lacks commit provenance"
      end

      measured_wall_ms = ((completed_at - started_at) * 1000).round
      if measured_wall_ms != wall_ms
        raise Invalid, "baseline run #{id} wall_ms disagrees with its timestamps"
      end

      {
        "id" => id,
        "wall_ms" => wall_ms,
        "event" => event,
        "conclusion" => conclusion,
        "started_at" => run.fetch("started_at"),
        "completed_at" => run.fetch("completed_at"),
        "head_sha" => head_sha
      }
    end
  rescue KeyError => e
    raise Invalid, "observed baseline is missing #{e.key}"
  rescue ArgumentError => e
    raise Invalid, "observed baseline timestamp is invalid: #{e.message}"
  end

  def derive(policy, runs)
    normalized = normalized_runs(policy, runs)
    values = normalized.map { |run| run.fetch("wall_ms") }
    p50 = percentile(values, 0.5)
    p90 = percentile(values, 0.9)
    maximum = values.max
    {
      "schema_version" => 2,
      "generator" => GENERATOR,
      "topology_epoch" => policy.fetch("topology_epoch"),
      "runs" => normalized,
      "wall" => {
        "sample_count" => normalized.length,
        "p50_ms" => p50,
        "p90_ms" => p90,
        "max_ms" => maximum,
        "p90_regression_limit_ms" => regression_limit(p90),
        "max_regression_limit_ms" => regression_limit(maximum)
      }
    }
  rescue KeyError => e
    raise Invalid, "policy is missing #{e.key}"
  end

  def validate(policy)
    baseline = policy["observed_baseline"]
    raise Invalid, "policy has no observed_baseline" unless baseline.is_a?(Hash)

    if baseline["schema_version"] == 1 && baseline["generator"] == "burin-ci-latency-baseline-v1"
      return validate_legacy_burin(policy, baseline)
    end
    unless baseline["schema_version"] == 2 && baseline["generator"] == GENERATOR
      raise Invalid, "observed_baseline has an unknown schema or generator"
    end

    expected = derive(policy, baseline.fetch("runs"))
    raise Invalid, "observed_baseline is not the generated projection of its runs" unless baseline == expected

    limits(expected)
  rescue KeyError => e
    raise Invalid, "observed baseline is missing #{e.key}"
  end

  def ratchet(policy, runs)
    candidate = derive(policy, runs)
    current = policy["observed_baseline"]
    if current.is_a?(Hash) && current["topology_epoch"] == policy.fetch("topology_epoch")
      current_limits = validate(policy)
      candidate_limits = limits(candidate)
      %w[p50_ms p90_ms max_ms].each do |metric|
        next unless candidate.dig("wall", metric) > current.dig("wall", metric)

        raise Invalid, "observed_baseline may only tighten: #{metric} moved upward"
      end
      %w[p90_regression_limit_ms max_regression_limit_ms].each do |metric|
        next unless candidate_limits.fetch(metric) > current_limits.fetch(metric)

        raise Invalid, "observed_baseline may only tighten: #{metric} moved upward"
      end
    end
    policy.merge("observed_baseline" => candidate)
  end

  def limits(baseline)
    {
      "baseline_p90_ms" => baseline.dig("wall", "p90_ms"),
      "baseline_max_ms" => baseline.dig("wall", "max_ms"),
      "p90_regression_limit_ms" => baseline.dig("wall", "p90_regression_limit_ms"),
      "max_regression_limit_ms" => baseline.dig("wall", "max_regression_limit_ms")
    }
  end

  def validate_legacy_burin(policy, baseline)
    raise Invalid, "observed_baseline topology_epoch is stale" unless baseline["topology_epoch"] == policy["topology_epoch"]
    unless baseline["product_target_ms"] == policy.dig("slo", "p90_ms")
      raise Invalid, "observed_baseline was generated for a different product target"
    end

    runs = normalized_runs(policy, baseline.fetch("runs"))
    values = runs.map { |run| run.fetch("wall_ms") }
    wall = baseline.fetch("wall")
    expected_wall = {
      "sample_count" => runs.length,
      "p50_ms" => percentile(values, 0.5),
      "p90_ms" => percentile(values, 0.9),
      "max_ms" => values.max
    }
    expected_limit = [regression_limit(expected_wall.fetch("p90_ms")), policy.dig("slo", "hard_max_ms")].min
    expected_wall["regression_limit_ms"] = expected_limit
    expected = {
      "schema_version" => 1,
      "generator" => "burin-ci-latency-baseline-v1",
      "topology_epoch" => policy.fetch("topology_epoch"),
      "product_target_ms" => policy.dig("slo", "p90_ms"),
      "runs" => runs,
      "wall" => expected_wall,
      "required_jobs" => {
        "status" => "unmeasured",
        "reason" => "the run-level observer does not fetch per-required-job timings"
      }
    }
    unless baseline == expected
      raise Invalid, "observed_baseline is not the generated projection of its runs"
    end

    {
      "baseline_p90_ms" => wall.fetch("p90_ms"),
      "baseline_max_ms" => wall.fetch("max_ms"),
      "p90_regression_limit_ms" => wall.fetch("regression_limit_ms"),
      "max_regression_limit_ms" => regression_limit(wall.fetch("max_ms"))
    }
  end

  def positive_integer(hash, key)
    value = hash.fetch(key)
    raise Invalid, "#{key} must be a positive integer" unless value.is_a?(Integer) && value.positive?

    value
  end

  def parse_time(hash, key)
    value = hash.fetch(key)
    raise Invalid, "#{key} must be an ISO-8601 string" unless value.is_a?(String)

    Time.iso8601(value)
  end
end
