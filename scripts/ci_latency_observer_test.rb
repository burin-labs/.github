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
      result = CiLatencyObserver::CommandResult.new(
        stdout: JSON.generate(response),
        stderr: "",
        process_ok: true,
        accepted: false
      )
      raise "fixture response was rejected" unless accept.call(result)

      result.accepted = true
      result
    end
  end

  class CaptureRunner < CiLatencyObserver::Runner
    def initialize(result)
      @result = result
      @retry_delay = 0
    end

    private

    def capture(*)
      @result
    end
  end

  class SequenceProbeRunner < CiLatencyObserver::Runner
    def initialize(probes)
      super(
        reports: "/unused/reports",
        policies: "/unused/policies",
        harn_script: "/unused/measure.harn",
        summary_path: "/unused/summary",
        retry_delay: 0
      )
      @probes = probes
    end

    private

    def probe_full_success(*)
      @probes.shift || raise("probe fixture exhausted")
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

  def freshness_probe(run: expected_run, error: nil)
    {
      "query" => "/fixture",
      "candidate_limit" => 100,
      "candidate_count" => run ? 1 : 0,
      "eligible_candidate_count" => run ? 1 : 0,
      "inspected_count" => run ? 1 : 0,
      "truncated" => false,
      "selected_run" => run,
      "inspected_candidates" => [],
      "error" => error
    }
  end

  def baseline_runs(values)
    values.each_with_index.map do |wall_ms, index|
      started = Time.iso8601("2026-08-27T06:00:00Z") - index * 3600
      {
        "id" => 201 - index,
        "wall_ms" => wall_ms,
        "event" => "merge_group",
        "conclusion" => "success",
        "started_at" => started.iso8601,
        "completed_at" => (started + wall_ms / 1000).iso8601,
        "head_sha" => format("%040x", index + 1)
      }
    end
  end

  def attach_baseline(report, values: [957_000, 1_052_000, 1_067_000, 760_000, 1_061_000])
    report["policy"]["event"] = "merge_group"
    report["policy"]["topology_epoch"] = "2026-08-20T00:00:00Z"
    report["policy"] = CiLatencyBaseline.ratchet(report.fetch("policy"), baseline_runs(values))
    report
  end

  def test_valid_policy_breach_report_is_accepted_despite_process_failure
    report = healthy_report
    report["evaluation"]["status"] = "hard_max_breach"
    report["evaluation"]["ok"] = false
    result = CiLatencyObserver::CommandResult.new(
      stdout: JSON.generate(report),
      stderr: "policy threshold exceeded",
      process_ok: false,
      accepted: false
    )

    captured = CaptureRunner.new(result).send(
      :retry_capture,
      "harn",
      accept: lambda do |command_result|
        parsed = JSON.parse(command_result.stdout)
        CiLatencyObserver.report_error(parsed).nil?
      end
    )

    refute captured.process_ok
    assert captured.accepted
    assert_equal "hard_max_breach", JSON.parse(captured.stdout).dig("evaluation", "status")
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
    runs_path = "/repos/burin-labs/harn/actions/workflows/ci.yml/runs?event=pull_request&status=completed&per_page=100"
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

    probe = FakeRunner.new(responses).send(:probe_full_success, policy)
    run = probe.fetch("selected_run")

    assert_nil probe.fetch("error")
    assert_equal 104, run.fetch("id")
    assert_equal "2026-08-27T07:00:00Z", run.fetch("created_at")
    assert_equal 100, probe.fetch("candidate_limit")
    assert_equal 4, probe.fetch("candidate_count")
    assert_equal 1, probe.fetch("inspected_count")
    assert_equal [], probe.dig("inspected_candidates", 0, "missing_sentinels")
  end

  def test_exhausted_candidate_window_is_unknown_not_absent
    policy = {
      "repository" => "burin-labs/harn",
      "workflow" => "ci.yml",
      "event" => "pull_request",
      "topology_epoch" => "2026-08-27T00:00:00Z",
      "full_run_jobs" => [{"name" => "CI status", "match" => "exact"}]
    }
    runs_path = "/repos/burin-labs/harn/actions/workflows/ci.yml/runs?event=pull_request&status=completed&per_page=100"
    responses = {
      runs_path => {
        "workflow_runs" => 100.times.map do |index|
          {
            "id" => index + 1,
            "created_at" => "2026-08-27T06:00:00Z",
            "conclusion" => "failure"
          }
        end
      }
    }

    probe = FakeRunner.new(responses).send(:probe_full_success, policy)

    assert_nil probe.fetch("selected_run")
    assert probe.fetch("truncated")
    assert_equal 100, probe.fetch("candidate_count")
    assert_match(/candidate window exhausted/, probe.fetch("error"))
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

  def test_measured_target_debt_is_first_class_without_making_the_schedule_red
    report = attach_baseline(healthy_report)
    report["evaluation"] = {
      "status" => "hard_max_breach",
      "ok" => false,
      "current" => {"count" => 5, "p90_ms" => 1_064_600, "max_ms" => 1_067_000},
      "previous" => {"count" => 5, "p90_ms" => 1_499_400, "max_ms" => 1_515_000}
    }

    receipt = CiLatencyObserver.classify(report, expected_run: expected_run)

    assert_equal "target_debt", receipt.fetch("status")
    assert_equal 0, CiLatencyObserver.exit_status([receipt])
    assert_empty receipt.fetch("breaches")
    assert_equal [
      {
        "metric" => "evaluation.current.p90_ms",
        "observed_ms" => 1_064_600,
        "target_ms" => 600_000,
        "gap_ms" => 464_600,
        "sample_count" => 5
      },
      {
        "metric" => "evaluation.current.max_ms",
        "observed_ms" => 1_067_000,
        "target_ms" => 900_000,
        "gap_ms" => 167_000,
        "sample_count" => 5
      }
    ], receipt.fetch("target_debt")
    assert_equal 1_173_700, receipt.dig("observed_baseline", "p90_regression_limit_ms")
    assert_equal "warming", receipt.dig("regression_window", "p90_status")
    assert_equal 0, receipt.dig("regression_window", "post_baseline_sample_count")
  end

  def test_fetched_policy_supplies_baseline_dropped_by_the_typed_measurement_projection
    full_report = attach_baseline(healthy_report)
    full_report["evaluation"] = {
      "status" => "hard_max_breach",
      "ok" => false,
      "current" => {"count" => 5, "p90_ms" => 1_064_600, "max_ms" => 1_067_000},
      "previous" => {"count" => 5, "p90_ms" => 1_499_400, "max_ms" => 1_515_000}
    }
    fetched_policy = full_report.fetch("policy")
    producer_report = Marshal.load(Marshal.dump(full_report))
    producer_report["policy"].delete("observed_baseline")

    receipt = CiLatencyObserver.classify(
      producer_report,
      expected_run: expected_run,
      policy: fetched_policy
    )

    assert_equal "target_debt", receipt.fetch("status")
    assert_equal 0, CiLatencyObserver.exit_status([receipt])
  end

  def test_measurement_policy_projection_mismatch_fails_closed
    report = healthy_report
    fetched_policy = Marshal.load(Marshal.dump(report.fetch("policy")))
    fetched_policy["slo"]["p90_ms"] = 700_000

    receipt = CiLatencyObserver.classify(report, expected_run: expected_run, policy: fetched_policy)

    assert_equal "observer_error", receipt.fetch("status")
    assert_match(/does not match/, receipt.fetch("error"))
    assert_equal 1, CiLatencyObserver.exit_status([receipt])
  end

  def test_sustained_p90_or_immediate_max_regression_still_fails
    report = attach_baseline(healthy_report)
    report["qualifying_runs"].each do |run|
      run["created_at"] = "2026-08-28T06:00:00Z"
    end
    report["evaluation"] = {
      "status" => "hard_max_breach",
      "ok" => false,
      "current" => {"count" => 5, "p90_ms" => 1_300_000, "max_ms" => 1_350_000},
      "previous" => {"count" => 5, "p90_ms" => 1_250_000, "max_ms" => 1_260_000}
    }

    receipt = CiLatencyObserver.classify(
      report,
      expected_run: {"id" => 101, "created_at" => "2026-08-28T06:00:00Z"}
    )

    assert_equal "policy_breach", receipt.fetch("status")
    assert_equal 1, CiLatencyObserver.exit_status([receipt])
    assert_equal [
      "evaluation.current.p90_ms",
      "evaluation.previous.p90_ms",
      "evaluation.current.max_ms"
    ], receipt.fetch("breaches").map { |breach| breach.fetch("metric") }
    assert receipt.fetch("breaches").all? { |breach| breach.fetch("threshold_ms") == 1_173_700 }
    assert_equal "enforcing", receipt.dig("regression_window", "p90_status")
  end

  def test_pre_baseline_history_cannot_supply_half_of_a_sustained_regression
    report = attach_baseline(healthy_report)
    report["evaluation"] = {
      "status" => "sustained_p90_breach",
      "ok" => false,
      "current" => {"count" => 5, "p90_ms" => 1_300_000, "max_ms" => 1_100_000},
      "previous" => {"count" => 5, "p90_ms" => 1_250_000, "max_ms" => 1_100_000}
    }

    receipt = CiLatencyObserver.classify(report, expected_run: expected_run)

    assert_equal "target_debt", receipt.fetch("status")
    assert_empty receipt.fetch("breaches")
    assert_equal "warming", receipt.dig("regression_window", "p90_status")
  end

  def test_max_regression_is_immediate_while_p90_window_is_warming
    report = attach_baseline(healthy_report)
    report["evaluation"] = {
      "status" => "hard_max_breach",
      "ok" => false,
      "current" => {"count" => 5, "p90_ms" => 1_064_600, "max_ms" => 1_300_000},
      "previous" => {"count" => 5, "p90_ms" => 1_499_400, "max_ms" => 1_515_000}
    }

    receipt = CiLatencyObserver.classify(report, expected_run: expected_run)

    assert_equal "policy_breach", receipt.fetch("status")
    assert_equal ["evaluation.current.max_ms"], receipt.fetch("breaches").map { |breach| breach.fetch("metric") }
    assert_equal "warming", receipt.dig("regression_window", "p90_status")
  end

  def test_invalid_or_empty_baseline_evidence_fails_closed
    report = attach_baseline(healthy_report)
    report["policy"]["observed_baseline"]["wall"]["p90_ms"] = 600_000

    receipt = CiLatencyObserver.classify(report, expected_run: expected_run)

    assert_equal "observer_error", receipt.fetch("status")
    assert_match(/observed baseline is invalid/, receipt.fetch("error"))
    assert_equal 1, CiLatencyObserver.exit_status([receipt])
  end

  def test_stale_success_window_is_an_observer_error_not_a_policy_breach
    receipt = CiLatencyObserver.classify(healthy_report(run_id: 100), expected_run: expected_run)

    assert_equal "stale", receipt.fetch("status")
    assert_equal "burin-labs/harn", receipt.fetch("repository")
    assert_equal 101, receipt.dig("freshness", "expected_run_id")
    assert_equal 100, receipt.dig("freshness", "observed_run_id")
    assert_equal 1, CiLatencyObserver.exit_status([receipt])
  end

  def test_transient_freshness_disagreement_requires_two_matching_semantic_retries
    measured = expected_run(id: 103)
    initial = freshness_probe(run: expected_run(id: 101))
    runner = SequenceProbeRunner.new([
      freshness_probe(run: measured),
      freshness_probe(run: measured)
    ])

    selected, probes, error = runner.send(:reconcile_freshness, healthy_report.fetch("policy"), measured, initial)

    assert_nil error
    assert_equal 103, selected.fetch("id")
    assert_equal [101, 103, 103], probes.map { |probe| probe.dig("selected_run", "id") }
  end

  def test_stable_freshness_disagreement_remains_fail_closed
    measured = expected_run(id: 103)
    stale = freshness_probe(run: expected_run(id: 101))
    runner = SequenceProbeRunner.new([stale, stale])

    selected, probes, error = runner.send(:reconcile_freshness, healthy_report.fetch("policy"), measured, stale)
    receipt = CiLatencyObserver.classify(healthy_report(run_id: 103), expected_run: selected, error: error)

    assert_nil error
    assert_equal 101, selected.fetch("id")
    assert_equal 3, probes.count
    assert_equal "stale", receipt.fetch("status")
  end

  def test_absent_probe_cannot_confirm_a_non_null_measurement
    measured = expected_run(id: 103)
    absent = freshness_probe(run: nil)
    runner = SequenceProbeRunner.new([absent, absent])

    selected, probes, error = runner.send(:reconcile_freshness, healthy_report.fetch("policy"), measured, absent)
    receipt = CiLatencyObserver.classify(healthy_report(run_id: 103), expected_run: selected, error: error)

    assert_nil error
    assert_nil selected
    assert_equal 3, probes.count
    assert_equal "observer_error", receipt.fetch("status")
    assert_match(/freshness probe/, receipt.fetch("error"))
  end

  def test_failed_probe_is_preserved_without_spending_semantic_retries
    measured = expected_run(id: 103)
    failed = freshness_probe(run: nil, error: "freshness read failed: timeout")
    runner = SequenceProbeRunner.new([])

    selected, probes, error = runner.send(:reconcile_freshness, healthy_report.fetch("policy"), measured, failed)
    receipt = CiLatencyObserver.classify(healthy_report(run_id: 103), expected_run: selected, error: error)

    assert_nil selected
    assert_equal [failed], probes
    assert_equal "freshness read failed: timeout", error
    assert_equal "observer_error", receipt.fetch("status")
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
      "current" => {"count" => 0, "p90_ms" => 0, "max_ms" => 0},
      "previous" => {"count" => 0, "p90_ms" => 0, "max_ms" => 0}
    }
    pending = CiLatencyObserver.classify(pending_report, expected_run: nil)

    summary = CiLatencyObserver.summary([healthy, stale, pending])

    assert_equal 2, summary.fetch("schema_version")
    assert_equal 3, summary.fetch("repository_count")
    assert_equal 1, summary.fetch("passing_count")
    assert_equal 1, summary.fetch("stale_count")
    assert_equal 1, summary.fetch("pending_count")
    assert_equal 0, summary.fetch("breach_count")
    assert_equal 0, summary.fetch("target_debt_count")
    assert_equal 0, summary.fetch("observer_error_count")
    assert_equal 5, summary.fetch("repositories").first.dig("current_window", "count")
    assert_equal 5, summary.fetch("repositories").first.dig("previous_window", "count")
    assert_equal 101, summary.fetch("repositories").first.dig("freshness", "observed_run_id")
    assert_equal 600_000, summary.fetch("repositories").first.dig("thresholds", "p90_ms")
    assert_equal ["burin-labs/burin-code"], summary.fetch("stale_repositories")
    assert_equal ["burin-labs/harn-cloud"], summary.fetch("pending_repositories")
    assert_equal [], summary.fetch("breaching_repositories")
    assert_equal [], summary.fetch("target_debt_repositories")
    assert_equal [], summary.fetch("observer_error_repositories")
  end
end
