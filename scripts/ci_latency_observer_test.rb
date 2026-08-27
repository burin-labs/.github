# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "ci_latency_observer"

class CiLatencyObserverTest < Minitest::Test
  class FakeRunner < CiLatencyObserver::Runner
    def initialize(responses)
      @responses = responses
    end

    private

    def retry_capture(*args, accept:)
      response = @responses.fetch(args.last)
      result = [JSON.generate(response), "", true]
      raise "fixture response was rejected" unless accept.call(result)

      result
    end
  end

  def healthy_report(repository: "burin-labs/harn", run_id: 101)
    {
      "schema_version" => 2,
      "policy" => {
        "repository" => repository,
        "slo" => {
          "warning_ms" => 540_000,
          "p90_ms" => 600_000,
          "hard_max_ms" => 900_000,
          "min_samples" => 5,
          "window_samples" => 5
        }
      },
      "qualifying_runs" => 10.times.map do |offset|
        {"id" => run_id - offset, "created_at" => "2026-08-27T06:00:00Z", "duration_ms" => 580_000}
      end,
      "wall" => {"count" => 10, "p50_ms" => 500_000, "p90_ms" => 580_000, "max_ms" => 590_000},
      "evaluation" => {
        "status" => "healthy",
        "ok" => true,
        "current" => {"count" => 5, "p90_ms" => 580_000, "max_ms" => 590_000},
        "previous" => {"count" => 5, "p90_ms" => 570_000, "max_ms" => 580_000}
      }
    }
  end

  def expected_run(id: 101)
    {"id" => id, "created_at" => "2026-08-27T06:00:00Z"}
  end

  def test_fresh_healthy_report_is_the_only_terminal_success
    receipt = CiLatencyObserver.classify(healthy_report, expected_run: expected_run)

    assert_equal "pass", receipt.fetch("status")
    assert_equal 0, CiLatencyObserver.exit_status([receipt])
    assert_equal 101, receipt.dig("freshness", "expected_run_id")
    assert_equal 101, receipt.dig("freshness", "observed_run_id")
  end

  def test_shuffled_report_runs_select_newest_by_time_then_id
    report = healthy_report
    report["qualifying_runs"][0] = {
      "id" => 109,
      "created_at" => "2026-08-27T07:00:00Z",
      "duration_ms" => 580_000
    }
    report["qualifying_runs"][7] = {
      "id" => 110,
      "created_at" => "2026-08-27T07:00:00Z",
      "duration_ms" => 580_000
    }

    receipt = CiLatencyObserver.classify(
      report,
      expected_run: {"id" => 110, "created_at" => "2026-08-27T07:00:00Z"}
    )

    assert_equal "pass", receipt.fetch("status")
    assert_equal 110, receipt.dig("freshness", "observed_run_id")
  end

  def test_shuffled_api_runs_select_newest_full_coverage_identity
    policy = {
      "repository" => "burin-labs/harn",
      "workflow" => "ci.yml",
      "event" => "pull_request",
      "topology_epoch" => "2026-08-27T00:00:00Z",
      "full_run_jobs" => [{"name" => "CI status", "match" => "exact"}]
    }
    runs_path = "/repos/burin-labs/harn/actions/workflows/ci.yml/runs?event=pull_request&status=completed&per_page=20"
    jobs = {"jobs" => [{"name" => "CI status", "conclusion" => "success"}]}
    responses = {
      runs_path => {
        "workflow_runs" => [
          {"id" => 101, "created_at" => "2026-08-27T05:00:00Z", "conclusion" => "success"},
          {"id" => 103, "created_at" => "2026-08-27T07:00:00Z", "conclusion" => "success"},
          {"id" => 104, "created_at" => "2026-08-27T07:00:00Z", "conclusion" => "success"},
          {"id" => 102, "created_at" => "2026-08-27T06:00:00Z", "conclusion" => "success"}
        ]
      },
      "/repos/burin-labs/harn/actions/runs/101/jobs?per_page=100" => jobs,
      "/repos/burin-labs/harn/actions/runs/102/jobs?per_page=100" => jobs,
      "/repos/burin-labs/harn/actions/runs/103/jobs?per_page=100" => jobs,
      "/repos/burin-labs/harn/actions/runs/104/jobs?per_page=100" => jobs
    }

    run, error = FakeRunner.new(responses).send(:latest_full_success, policy)

    assert_nil error
    assert_equal 104, run.fetch("id")
    assert_equal "2026-08-27T07:00:00Z", run.fetch("created_at")
  end

  def test_unknown_producer_status_fails_closed
    report = healthy_report
    report["evaluation"]["status"] = "typo"

    receipt = CiLatencyObserver.classify(report, expected_run: expected_run)

    assert_equal "observer_error", receipt.fetch("status")
    assert_match(/recognized producer status/, receipt.fetch("error"))
    assert_equal 1, CiLatencyObserver.exit_status([receipt])
  end

  def test_contradictory_producer_status_and_ok_fail_closed
    report = healthy_report
    report["evaluation"]["ok"] = false

    receipt = CiLatencyObserver.classify(report, expected_run: expected_run)

    assert_equal "observer_error", receipt.fetch("status")
    assert_match(/contradicts/, receipt.fetch("error"))
    assert_equal 1, CiLatencyObserver.exit_status([receipt])
  end

  def test_fresh_policy_breach_remains_enforcing_and_names_each_metric
    report = healthy_report
    report["evaluation"] = {
      "status" => "sustained_p90_breach",
      "ok" => false,
      "current" => {"count" => 5, "p90_ms" => 1_195_400, "max_ms" => 1_241_000},
      "previous" => {"count" => 5, "p90_ms" => 1_327_000, "max_ms" => 1_523_000}
    }

    receipt = CiLatencyObserver.classify(report, expected_run: expected_run)

    assert_equal "policy_breach", receipt.fetch("status")
    assert_equal 1, CiLatencyObserver.exit_status([receipt])
    assert_equal [
      {
        "metric" => "evaluation.current.p90_ms",
        "observed_ms" => 1_195_400,
        "threshold_ms" => 600_000,
        "sample_count" => 5
      },
      {
        "metric" => "evaluation.previous.p90_ms",
        "observed_ms" => 1_327_000,
        "threshold_ms" => 600_000,
        "sample_count" => 5
      },
      {
        "metric" => "evaluation.current.max_ms",
        "observed_ms" => 1_241_000,
        "threshold_ms" => 900_000,
        "sample_count" => 5
      }
    ], receipt.fetch("breaches")
  end

  def test_stale_success_window_is_an_observer_error_not_a_policy_breach
    receipt = CiLatencyObserver.classify(healthy_report(run_id: 100), expected_run: expected_run)

    assert_equal "stale", receipt.fetch("status")
    assert_equal "burin-labs/harn", receipt.fetch("repository")
    assert_equal 101, receipt.dig("freshness", "expected_run_id")
    assert_equal 100, receipt.dig("freshness", "observed_run_id")
    assert_equal 1, CiLatencyObserver.exit_status([receipt])
  end

  def test_missing_independent_freshness_receipt_cannot_make_old_samples_pass
    receipt = CiLatencyObserver.classify(healthy_report, expected_run: nil)

    assert_equal "observer_error", receipt.fetch("status")
    assert_match(/freshness probe/, receipt.fetch("error"))
    assert_equal 101, receipt.dig("freshness", "observed_run_id")
    assert_equal 1, CiLatencyObserver.exit_status([receipt])
  end

  def test_zero_samples_are_pending_and_never_success
    report = healthy_report
    report["qualifying_runs"] = []
    report["wall"] = {"count" => 0, "p50_ms" => 0, "p90_ms" => 0, "max_ms" => 0}
    report["evaluation"] = {
      "status" => "insufficient_samples",
      "ok" => false,
      "current" => {"count" => 0, "p90_ms" => 0, "max_ms" => 0},
      "previous" => {"count" => 0, "p90_ms" => 0, "max_ms" => 0}
    }

    receipt = CiLatencyObserver.classify(report, expected_run: nil)

    assert_equal "insufficient_samples", receipt.fetch("status")
    assert_equal 0, receipt.fetch("sample_count")
    assert_equal "absent", receipt.dig("freshness", "status")
    assert_equal 1, CiLatencyObserver.exit_status([receipt])
  end

  def test_zero_samples_with_a_healthy_label_are_rejected_as_vacuous
    report = healthy_report
    report["qualifying_runs"] = []
    report["wall"]["count"] = 0

    receipt = CiLatencyObserver.classify(report, expected_run: nil)

    assert_equal "observer_error", receipt.fetch("status")
    assert_match(/zero qualifying runs/, receipt.fetch("error"))
    assert_equal 1, CiLatencyObserver.exit_status([receipt])
  end

  def test_invalid_report_is_named_and_fails_closed
    receipt = CiLatencyObserver.classify({"schema_version" => 2}, expected_run: expected_run)

    assert_equal "observer_error", receipt.fetch("status")
    assert_match(/policy\.repository/, receipt.fetch("error"))
    assert_equal 1, CiLatencyObserver.exit_status([receipt])
  end

  def test_absent_report_is_named_and_fails_closed
    receipt = CiLatencyObserver.classify(nil, expected_run: expected_run)

    assert_equal "observer_error", receipt.fetch("status")
    assert_equal "unknown", receipt.fetch("repository")
    assert_match(/JSON object/, receipt.fetch("error"))
    assert_equal 1, CiLatencyObserver.exit_status([receipt])
  end

  def test_summary_exposes_counts_and_names_without_collapsing_states
    healthy = CiLatencyObserver.classify(healthy_report(repository: "burin-labs/.github"), expected_run: expected_run)
    stale = CiLatencyObserver.classify(healthy_report(repository: "burin-labs/burin-code", run_id: 100), expected_run: expected_run)
    pending_report = healthy_report(repository: "burin-labs/harn-cloud")
    pending_report["qualifying_runs"] = []
    pending_report["wall"]["count"] = 0
    pending_report["evaluation"] = {
      "status" => "insufficient_samples", "ok" => false,
      "current" => {"count" => 0}, "previous" => {"count" => 0}
    }
    pending = CiLatencyObserver.classify(pending_report, expected_run: nil)

    summary = CiLatencyObserver.summary([healthy, stale, pending])

    assert_equal 3, summary.fetch("repository_count")
    assert_equal 1, summary.fetch("passing_count")
    assert_equal 1, summary.fetch("stale_count")
    assert_equal 1, summary.fetch("pending_count")
    assert_equal 0, summary.fetch("breach_count")
    assert_equal 0, summary.fetch("observer_error_count")
    assert_equal 5, summary.fetch("repositories").first.dig("current_window", "count")
    assert_equal 5, summary.fetch("repositories").first.dig("previous_window", "count")
    assert_equal 101, summary.fetch("repositories").first.dig("freshness", "observed_run_id")
    assert_equal 600_000, summary.fetch("repositories").first.dig("thresholds", "p90_ms")
    assert_equal ["burin-labs/burin-code"], summary.fetch("stale_repositories")
    assert_equal ["burin-labs/harn-cloud"], summary.fetch("pending_repositories")
    assert_equal [], summary.fetch("breaching_repositories")
    assert_equal [], summary.fetch("observer_error_repositories")
  end
end
