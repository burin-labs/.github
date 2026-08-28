# frozen_string_literal: true

require "minitest/autorun"
require_relative "ci_latency_baseline"

class CiLatencyBaselineTest < Minitest::Test
  def policy
    {
      "event" => "merge_group",
      "topology_epoch" => "2026-08-20T00:00:00Z",
      "slo" => {
        "p90_ms" => 600_000,
        "hard_max_ms" => 900_000,
        "min_samples" => 5,
        "window_samples" => 5
      }
    }
  end

  def runs(values)
    values.each_with_index.map do |wall_ms, index|
      started = Time.iso8601("2026-08-27T06:00:00Z") - index * 3600
      {
        "id" => 100 - index,
        "wall_ms" => wall_ms,
        "event" => "merge_group",
        "conclusion" => "success",
        "started_at" => started.iso8601,
        "completed_at" => (started + wall_ms / 1000).iso8601,
        "head_sha" => format("%040x", index + 1)
      }
    end
  end

  def test_derives_reproducible_limits_from_a_nonempty_window
    baseline = CiLatencyBaseline.derive(policy, runs([957_000, 1_052_000, 1_067_000, 760_000, 1_061_000]))

    assert_equal 5, baseline.dig("wall", "sample_count")
    assert_equal 1_067_000, baseline.dig("wall", "p90_ms")
    assert_equal 1_173_700, baseline.dig("wall", "p90_regression_limit_ms")
    assert_equal 1_173_700, baseline.dig("wall", "max_regression_limit_ms")
    assert_equal CiLatencyBaseline.limits(baseline), CiLatencyBaseline.validate(policy.merge("observed_baseline" => baseline))
  end

  def test_absent_or_tampered_evidence_fails_closed
    error = assert_raises(CiLatencyBaseline::Invalid) do
      CiLatencyBaseline.derive(policy, [])
    end
    assert_match(/requires 5/, error.message)

    baseline = CiLatencyBaseline.derive(policy, runs([957_000, 1_052_000, 1_067_000, 760_000, 1_061_000]))
    baseline["wall"]["p90_ms"] = 600_000
    error = assert_raises(CiLatencyBaseline::Invalid) do
      CiLatencyBaseline.validate(policy.merge("observed_baseline" => baseline))
    end
    assert_match(/not the generated projection/, error.message)
  end

  def test_same_topology_ratchet_can_only_tighten
    current = CiLatencyBaseline.ratchet(policy, runs([957_000, 1_052_000, 1_067_000, 760_000, 1_061_000]))
    faster = runs([700_000, 720_000, 740_000, 760_000, 780_000])
    ratcheted = CiLatencyBaseline.ratchet(current, faster)
    assert_equal 780_000, ratcheted.dig("observed_baseline", "wall", "p90_ms")

    slower = runs([1_100_000, 1_120_000, 1_140_000, 1_160_000, 1_180_000])
    error = assert_raises(CiLatencyBaseline::Invalid) do
      CiLatencyBaseline.ratchet(current, slower)
    end
    assert_match(/may only tighten/, error.message)
  end

  def test_topology_change_is_an_explicit_reset_boundary
    current = CiLatencyBaseline.ratchet(policy, runs([700_000, 720_000, 740_000, 760_000, 780_000]))
    reset = current.merge("topology_epoch" => "2026-08-27T00:00:00Z")
    slower = runs([1_100_000, 1_120_000, 1_140_000, 1_160_000, 1_180_000]).map do |run|
      run.merge(
        "started_at" => "2026-08-27T06:00:00Z",
        "completed_at" => (Time.iso8601("2026-08-27T06:00:00Z") + run.fetch("wall_ms") / 1000).iso8601
      )
    end
    candidate = CiLatencyBaseline.ratchet(reset, slower)
    assert_equal 1_180_000, candidate.dig("observed_baseline", "wall", "p90_ms")
  end
end
