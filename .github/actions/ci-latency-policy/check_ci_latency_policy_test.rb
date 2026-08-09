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
