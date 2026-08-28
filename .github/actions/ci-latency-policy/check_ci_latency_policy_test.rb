# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "check_ci_latency_policy"

class CiLatencyPolicyTest < Minitest::Test
  def policy(jobs: { "build" => { "budget_ms" => 500_000 } }, allowance: 600_000)
    {
      "schema_version" => 1,
      "repository" => "burin-labs/example",
      "workflow" => "ci.yml",
      "event" => "merge_group",
      "topology_epoch" => "2026-08-08T00:00:00Z",
      "full_run_jobs" => [{ "name" => "Build", "match" => "exact" }],
      "slo" => {
        "warning_ms" => 540_000,
        "p90_ms" => 600_000,
        "hard_max_ms" => 900_000,
        "min_samples" => 5,
        "window_samples" => 5
      },
      "required" => {
        "aggregate_job" => "status",
        "critical_path_allowance_ms" => allowance,
        "jobs" => jobs
      }
    }
  end

  def with_files(candidate:, workflow: nil, baseline: nil)
    files = [Tempfile.new(["policy", ".json"]), Tempfile.new(["workflow", ".yml"])]
    files[0].write(JSON.dump(candidate))
    files[0].flush
    files[1].write(workflow || "jobs:\n  build: {}\n  status:\n    needs: [build]\n")
    files[1].flush
    if baseline
      files << Tempfile.new(["baseline", ".json"])
      files[2].write(JSON.dump(baseline))
      files[2].flush
    end
    yield files
  ensure
    files&.each(&:close!)
  end

  def test_accepts_complete_down_only_contract
    with_files(candidate: policy, baseline: policy(allowance: 650_000)) do |files|
      result = CiLatencyPolicy.check(
        policy_path: files[0].path,
        workflow_path: files[1].path,
        baseline_path: files[2].path,
        repository: "burin-labs/example"
      )
      assert_equal 600_000, result.dig("slo", "p90_ms")
    end
  end

  def test_rejects_wrong_repository_or_relaxed_slo
    with_files(candidate: policy) do |files|
      error = assert_raises(CiLatencyPolicy::Invalid) do
        CiLatencyPolicy.check(
          policy_path: files[0].path,
          workflow_path: files[1].path,
          repository: "burin-labs/not-example"
        )
      end
      assert_includes error.message, "does not match"
    end

    candidate = policy
    candidate["slo"]["p90_ms"] = 610_000
    candidate["slo"]["hard_max_ms"] = 910_000
    with_files(candidate: candidate, baseline: policy) do |files|
      error = assert_raises(CiLatencyPolicy::Invalid) do
        CiLatencyPolicy.check(policy_path: files[0].path, workflow_path: files[1].path, baseline_path: files[2].path)
      end
      assert_includes error.message, "p90_ms may only decrease"
    end
  end

  def test_rejects_undeclared_required_job
    with_files(candidate: policy, workflow: "jobs:\n  build: {}\n  test: {}\n  status:\n    needs: [build, test]\n") do |files|
      error = assert_raises(CiLatencyPolicy::Invalid) do
        CiLatencyPolicy.check(policy_path: files[0].path, workflow_path: files[1].path)
      end
      assert_includes error.message, "test"
    end
  end

  def test_rejects_stale_budget
    with_files(candidate: policy(jobs: { "build" => { "budget_ms" => 500_000 }, "old" => { "budget_ms" => 1 } })) do |files|
      error = assert_raises(CiLatencyPolicy::Invalid) do
        CiLatencyPolicy.check(policy_path: files[0].path, workflow_path: files[1].path)
      end
      assert_includes error.message, "old"
    end
  end

  def test_rejects_upward_allowance_or_job_budget
    with_files(candidate: policy(allowance: 700_000), baseline: policy(allowance: 600_000)) do |files|
      assert_raises(CiLatencyPolicy::Invalid) do
        CiLatencyPolicy.check(policy_path: files[0].path, workflow_path: files[1].path, baseline_path: files[2].path)
      end
    end
    with_files(candidate: policy(jobs: { "build" => { "budget_ms" => 550_000 } }), baseline: policy) do |files|
      error = assert_raises(CiLatencyPolicy::Invalid) do
        CiLatencyPolicy.check(policy_path: files[0].path, workflow_path: files[1].path, baseline_path: files[2].path)
      end
      assert_includes error.message, "build"
    end
  end

  def receipt(observed_p90_ms: 700_000, sample_count: 10)
    {
      "sampled_at" => "2026-08-19T18:00:00Z",
      "source" => "actions/workflows/ci.yml/runs?event=merge_group&status=completed",
      "sample_count" => sample_count,
      "observed_p90_ms" => observed_p90_ms
    }
  end

  def baseline_runs(values)
    values.each_with_index.map do |wall_ms, index|
      started = Time.iso8601("2026-08-19T18:00:00Z") - index * 3600
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

  def with_observed_baseline(candidate, values)
    CiLatencyBaseline.ratchet(candidate, baseline_runs(values))
  end

  def test_accepts_initial_observed_baseline_and_rejects_tampering
    candidate = with_observed_baseline(policy, [500_000, 510_000, 520_000, 530_000, 540_000])
    with_files(candidate: candidate) do |files|
      result = CiLatencyPolicy.check(policy_path: files[0].path, workflow_path: files[1].path)
      assert_equal 600_000, result.dig("observed_baseline", "wall", "p90_regression_limit_ms")
    end

    candidate["observed_baseline"]["wall"]["p90_ms"] = 1
    with_files(candidate: candidate) do |files|
      error = assert_raises(CiLatencyPolicy::Invalid) do
        CiLatencyPolicy.check(policy_path: files[0].path, workflow_path: files[1].path)
      end
      assert_match(/not the generated projection/, error.message)
    end
  end

  def test_observed_baseline_cannot_be_removed_or_loosened_within_a_topology
    baseline = with_observed_baseline(policy, [500_000, 510_000, 520_000, 530_000, 540_000])
    with_files(candidate: policy, baseline: baseline) do |files|
      error = assert_raises(CiLatencyPolicy::Invalid) do
        CiLatencyPolicy.check(policy_path: files[0].path, workflow_path: files[1].path, baseline_path: files[2].path)
      end
      assert_match(/cannot be removed/, error.message)
    end

    slower = with_observed_baseline(policy, [510_000, 520_000, 530_000, 540_000, 550_000])
    with_files(candidate: slower, baseline: baseline) do |files|
      error = assert_raises(CiLatencyPolicy::Invalid) do
        CiLatencyPolicy.check(policy_path: files[0].path, workflow_path: files[1].path, baseline_path: files[2].path)
      end
      assert_match(/may only tighten/, error.message)
    end
  end

  # 700_000 * 1.2 = 840_000, already on the 6000ms grid; warning floors to
  # 756_000. hard_max stays above both, so ordering holds.
  def regenerated_policy
    candidate = policy
    candidate["slo"]["p90_ms"] = 840_000
    candidate["slo"]["warning_ms"] = 756_000
    candidate["slo"]["regenerated"] = receipt
    candidate
  end

  def test_accepts_slo_increase_that_matches_its_regeneration_receipt
    with_files(candidate: regenerated_policy, baseline: policy) do |files|
      result = CiLatencyPolicy.check(
        policy_path: files[0].path,
        workflow_path: files[1].path,
        baseline_path: files[2].path
      )
      assert_equal 840_000, result.dig("slo", "p90_ms")
      assert_equal 756_000, result.dig("slo", "warning_ms")
    end
  end

  def test_rejects_slo_increase_that_is_not_the_receipt_derivation
    candidate = regenerated_policy
    candidate["slo"]["p90_ms"] = 850_000
    with_files(candidate: candidate, baseline: policy) do |files|
      error = assert_raises(CiLatencyPolicy::Invalid) do
        CiLatencyPolicy.check(policy_path: files[0].path, workflow_path: files[1].path, baseline_path: files[2].path)
      end
      assert_includes error.message, "not the receipt's derivation 840000"
    end
  end

  def test_rejects_slo_increase_without_a_receipt
    candidate = regenerated_policy
    candidate["slo"].delete("regenerated")
    with_files(candidate: candidate, baseline: policy) do |files|
      error = assert_raises(CiLatencyPolicy::Invalid) do
        CiLatencyPolicy.check(policy_path: files[0].path, workflow_path: files[1].path, baseline_path: files[2].path)
      end
      assert_includes error.message, "without a slo.regenerated receipt"
    end
  end

  def test_rejects_receipt_with_fewer_samples_than_the_contract_requires
    candidate = regenerated_policy
    candidate["slo"]["regenerated"] = receipt(sample_count: 3)
    with_files(candidate: candidate) do |files|
      error = assert_raises(CiLatencyPolicy::Invalid) do
        CiLatencyPolicy.check(policy_path: files[0].path, workflow_path: files[1].path)
      end
      assert_includes error.message, "below slo.min_samples"
    end
  end

  def test_rejects_receipt_sampled_before_the_topology_epoch
    candidate = regenerated_policy
    candidate["slo"]["regenerated"]["sampled_at"] = "2026-08-07T00:00:00Z"
    with_files(candidate: candidate) do |files|
      error = assert_raises(CiLatencyPolicy::Invalid) do
        CiLatencyPolicy.check(policy_path: files[0].path, workflow_path: files[1].path)
      end
      assert_includes error.message, "predates topology_epoch"
    end
  end

  def test_rejects_warning_increase_that_is_not_paired_with_the_p90_derivation
    candidate = policy
    candidate["slo"]["warning_ms"] = 560_000
    with_files(candidate: candidate, baseline: policy) do |files|
      error = assert_raises(CiLatencyPolicy::Invalid) do
        CiLatencyPolicy.check(policy_path: files[0].path, workflow_path: files[1].path, baseline_path: files[2].path)
      end
      assert_includes error.message, "warning_ms may only decrease"
    end
  end

  def test_hard_max_stays_downward_only_even_with_a_receipt
    candidate = regenerated_policy
    candidate["slo"]["hard_max_ms"] = 910_000
    with_files(candidate: candidate, baseline: policy) do |files|
      error = assert_raises(CiLatencyPolicy::Invalid) do
        CiLatencyPolicy.check(policy_path: files[0].path, workflow_path: files[1].path, baseline_path: files[2].path)
      end
      assert_includes error.message, "hard_max_ms may only decrease"
    end
  end

  def test_rejects_inverted_slo_and_empty_sentinels
    candidate = policy
    candidate["slo"]["warning_ms"] = 610_000
    candidate["full_run_jobs"] = []
    with_files(candidate: candidate) do |files|
      assert_raises(CiLatencyPolicy::Invalid) do
        CiLatencyPolicy.check(policy_path: files[0].path, workflow_path: files[1].path)
      end
    end
  end
end
